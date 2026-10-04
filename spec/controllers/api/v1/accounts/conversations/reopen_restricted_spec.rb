require 'rails_helper'

# No Chatwoot original, o agente que muda o status para "aberta" (reabrir) vira o responsável.
# Com visão restrita isso roubava o dono: o gestor ("Minhas"), participante de uma conversa
# resolvida do corretor (adicionado pelo mark-work do CRM), reabria e virava o responsável; a
# limpeza do responsável anterior então tirava o corretor da própria conversa. Agora o status
# muda, mas o responsável só troca se a regra de atribuição (change_assignee?) permitir.
describe 'POST /api/v1/accounts/{account.id}/conversations/{id}/toggle_status (reopen with restricted roles)', type: :request do
  let!(:account) { create(:account) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:broker) { create(:user, account: account, role: :agent) }
  let!(:manager) { create(:user, account: account, role: :agent) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:resolved) { create(:conversation, account: account, inbox: inbox, assignee: broker, status: :resolved) }
  let!(:ownerless_resolved) { create(:conversation, account: account, inbox: inbox, assignee: nil, status: :resolved) }

  def reopen(user, conversation)
    post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/toggle_status",
         params: { status: 'open' }, headers: user.create_new_auth_token, as: :json
  end

  def restrict!(user, permission)
    role = create(:custom_role, account: account, permissions: [permission])
    AccountUser.find_by(user: user, account: account).update!(role: :agent, custom_role: role)
  end

  before { create(:inbox_member, inbox: inbox, user: broker) }

  %w[conversation_participating_manage conversation_unassigned_manage].each do |permission|
    context "with the restricted visibility #{permission}" do
      before { restrict!(manager, permission) }

      it 'reopens a conversation he only participates in (not a member of the inbox) without taking the owner' do
        create(:conversation_participant, conversation: resolved, account: account, user: manager)

        reopen(manager, resolved)

        expect(response).to have_http_status(:success)
        expect(resolved.reload.status).to eq('open')
        expect(resolved.assignee_id).to eq(broker.id)
      end

      it 'reopens a conversation he participates in as a member of the inbox, without taking the owner' do
        create(:inbox_member, inbox: inbox, user: manager)
        create(:conversation_participant, conversation: resolved, account: account, user: manager)

        reopen(manager, resolved)

        expect(response).to have_http_status(:success)
        expect(resolved.reload.status).to eq('open')
        expect(resolved.assignee_id).to eq(broker.id)
      end

      it 'does not take away the access of the broker (owner) when the manager reopens' do
        create(:conversation_participant, conversation: resolved, account: account, user: manager)
        create(:conversation_participant, conversation: resolved, account: account, user: broker)

        reopen(manager, resolved)

        expect(resolved.reload.conversation_participants.pluck(:user_id)).to contain_exactly(manager.id, broker.id)
        get "/api/v1/accounts/#{account.id}/conversations/#{resolved.display_id}", headers: broker.create_new_auth_token, as: :json
        expect(response).to have_http_status(:ok)
      end

      it 'reopens his own conversation normally (he stays the owner)' do
        create(:inbox_member, inbox: inbox, user: manager)
        resolved.update!(assignee: manager)

        reopen(manager, resolved)

        expect(response).to have_http_status(:success)
        expect(resolved.reload.status).to eq('open')
        expect(resolved.assignee_id).to eq(manager.id)
      end

      it 'takes an ownerless conversation when he reopens it (the rule lets him assign himself)' do
        create(:conversation_participant, conversation: ownerless_resolved, account: account, user: manager)

        reopen(manager, ownerless_resolved)

        expect(response).to have_http_status(:success)
        expect(ownerless_resolved.reload.status).to eq('open')
        expect(ownerless_resolved.assignee_id).to eq(manager.id)
      end
    end
  end

  context 'with the "Todas" role (conversation_manage)' do
    before do
      create(:inbox_member, inbox: inbox, user: manager)
      restrict!(manager, 'conversation_manage')
    end

    it 'becomes the owner on reopen, like before' do
      reopen(manager, resolved)

      expect(resolved.reload.status).to eq('open')
      expect(resolved.assignee_id).to eq(manager.id)
    end
  end

  it 'makes an agent without custom role the owner on reopen, like before' do
    create(:inbox_member, inbox: inbox, user: manager)

    reopen(manager, resolved)

    expect(resolved.reload.status).to eq('open')
    expect(resolved.assignee_id).to eq(manager.id)
  end

  it 'leaves the owner alone when an administrator reopens, like before' do
    reopen(admin, resolved)

    expect(resolved.reload.status).to eq('open')
    expect(resolved.assignee_id).to eq(broker.id)
  end
end
