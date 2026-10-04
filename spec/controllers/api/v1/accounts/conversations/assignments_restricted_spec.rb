require 'rails_helper'

# Quem tem visão restrita ("Minhas" ou "Não atribuídas") e não é admin nem "Todas":
# - só se atribui a uma conversa que está SEM responsável;
# - só reatribui ou tira o responsável se ele mesmo for o responsável atual.
# Antes, show? bastava: um participante restrito tomava a conversa de outro ou tirava o dono.
# Admin, agente sem custom_role e "Todas" seguem como antes (a integração do CRM usa token de
# administrador da conta).
describe 'POST /api/v1/accounts/{account.id}/conversations/{id}/assignments (restricted roles)', type: :request do
  let!(:account) { create(:account) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:owner) { create(:user, account: account, role: :agent) }
  let!(:colleague) { create(:user, account: account, role: :agent) }
  let!(:restricted) { create(:user, account: account, role: :agent) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:owned) { create(:conversation, account: account, inbox: inbox, assignee: owner) }
  let!(:ownerless) { create(:conversation, account: account, inbox: inbox, assignee: nil) }

  def assign(user, conversation, params)
    post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/assignments",
         params: params, headers: user.create_new_auth_token, as: :json
  end

  def restrict!(user, permission)
    role = create(:custom_role, account: account, permissions: [permission])
    AccountUser.find_by(user: user, account: account).update!(role: :agent, custom_role: role)
  end

  before do
    [owner, colleague, restricted].each { |user| create(:inbox_member, inbox: inbox, user: user) }
  end

  %w[conversation_participating_manage conversation_unassigned_manage].each do |permission|
    context "with the restricted visibility #{permission}" do
      before { restrict!(restricted, permission) }

      context 'when he is only a participant of a conversation that has an owner' do
        before { create(:conversation_participant, conversation: owned, account: account, user: restricted) }

        it 'cannot take the conversation from the owner (401, nothing changes)' do
          assign(restricted, owned, assignee_id: restricted.id)

          expect(response).to have_http_status(:unauthorized)
          expect(owned.reload.assignee_id).to eq(owner.id)
        end

        it 'cannot hand it to someone else' do
          assign(restricted, owned, assignee_id: colleague.id)

          expect(response).to have_http_status(:unauthorized)
          expect(owned.reload.assignee_id).to eq(owner.id)
        end

        it 'cannot remove the owner (assignee_id null)' do
          assign(restricted, owned, assignee_id: nil)

          expect(response).to have_http_status(:unauthorized)
          expect(owned.reload.assignee_id).to eq(owner.id)
        end

        it 'cannot give the conversation to an agent bot' do
          bot = create(:agent_bot, account: account)

          assign(restricted, owned, assignee_id: bot.id, assignee_type: 'AgentBot')

          expect(response).to have_http_status(:unauthorized)
          expect(owned.reload.assignee_id).to eq(owner.id)
        end
      end

      context 'when the conversation has no owner and he can see it' do
        before { create(:conversation_participant, conversation: ownerless, account: account, user: restricted) }

        it 'can assign it to himself' do
          assign(restricted, ownerless, assignee_id: restricted.id)

          expect(response).to have_http_status(:success)
          expect(ownerless.reload.assignee_id).to eq(restricted.id)
        end

        it 'cannot assign it to someone else' do
          assign(restricted, ownerless, assignee_id: colleague.id)

          expect(response).to have_http_status(:unauthorized)
          expect(ownerless.reload.assignee_id).to be_nil
        end

        it 'cannot "unassign" it either (nothing to change, but still not his call)' do
          assign(restricted, ownerless, assignee_id: nil)

          expect(response).to have_http_status(:unauthorized)
        end
      end

      context 'when he is the current owner' do
        before { owned.update!(assignee: restricted) }

        it 'can hand it to a colleague' do
          assign(restricted, owned, assignee_id: colleague.id)

          expect(response).to have_http_status(:success)
          expect(owned.reload.assignee_id).to eq(colleague.id)
        end

        it 'can remove himself as owner' do
          assign(restricted, owned, assignee_id: nil)

          expect(response).to have_http_status(:success)
          expect(owned.reload.assignee_id).to be_nil
        end

        it 'can hand it to an agent bot' do
          bot = create(:agent_bot, account: account)

          assign(restricted, owned, assignee_id: bot.id, assignee_type: 'AgentBot')

          expect(response).to have_http_status(:success)
        end
      end

      it 'can still change the team of a conversation he sees (not an assignee change)' do
        team = create(:team, account: account)
        owned.update!(assignee: restricted)

        assign(restricted, owned, team_id: team.id)

        expect(response).to have_http_status(:success)
        expect(owned.reload.team_id).to eq(team.id)
      end
    end
  end

  # Trocar o time pode trocar o responsável: o AssignmentHandler zera o dono que não é do time novo e o
  # round-robin do time pode entregar a conversa a um colega. Para quem tem visão restrita, a troca
  # de time que mudaria o responsável exige a mesma regra da atribuição (change_assignee?).
  describe 'team changes that would change the owner' do
    let!(:team_without_owner) { create(:team, account: account, allow_auto_assign: false) }
    let!(:team_with_owner) { create(:team, account: account, allow_auto_assign: false) }
    let!(:auto_assign_team) { create(:team, account: account, allow_auto_assign: true) }

    before do
      create(:team_member, team: team_with_owner, user: owner)
      create(:team_member, team: team_without_owner, user: colleague)
      create(:team_member, team: auto_assign_team, user: colleague)
      restrict!(restricted, 'conversation_unassigned_manage')
      [owned, ownerless].each { |conversation| create(:conversation_participant, conversation: conversation, account: account, user: restricted) }
    end

    it 'refuses (401) a team without the owner on a conversation owned by someone else, and changes nothing' do
      assign(restricted, owned, team_id: team_without_owner.id)

      expect(response).to have_http_status(:unauthorized)
      expect(owned.reload.team_id).to be_nil
      expect(owned.assignee_id).to eq(owner.id)
    end

    it 'allows a team that already has the owner (the owner does not change)' do
      assign(restricted, owned, team_id: team_with_owner.id)

      expect(response).to have_http_status(:success)
      expect(owned.reload.team_id).to eq(team_with_owner.id)
      expect(owned.assignee_id).to eq(owner.id)
    end

    it 'allows the owner himself to move the conversation to a team without him' do
      owned.update!(assignee: restricted)

      assign(restricted, owned, team_id: team_without_owner.id)

      expect(response).to have_http_status(:success)
      expect(owned.reload.team_id).to eq(team_without_owner.id)
    end

    it 'refuses (401) an auto-assign team on an ownerless conversation (the round-robin would hand it to a colleague)' do
      assign(restricted, ownerless, team_id: auto_assign_team.id)

      expect(response).to have_http_status(:unauthorized)
      expect(ownerless.reload.team_id).to be_nil
    end

    it 'allows a team without auto assignment on an ownerless conversation' do
      assign(restricted, ownerless, team_id: team_without_owner.id)

      expect(response).to have_http_status(:success)
      expect(ownerless.reload.team_id).to eq(team_without_owner.id)
    end

    it 'allows removing the team (nothing happens to the owner)' do
      owned.update!(team: team_with_owner)

      assign(restricted, owned, team_id: nil)

      expect(response).to have_http_status(:success)
      expect(owned.reload.team_id).to be_nil
      expect(owned.assignee_id).to eq(owner.id)
    end

    it 'keeps the previous behaviour for an administrator and for an agent without custom role' do
      assign(admin, owned, team_id: team_without_owner.id)
      expect(response).to have_http_status(:success)
      expect(owned.reload.assignee_id).to be_nil

      owned.update!(assignee: owner, team: nil)
      assign(colleague, owned, team_id: team_without_owner.id)
      expect(response).to have_http_status(:success)
    end

    it 'keeps the previous behaviour for the "Todas" role' do
      restrict!(restricted, 'conversation_manage')

      assign(restricted, owned, team_id: team_without_owner.id)

      expect(response).to have_http_status(:success)
      expect(owned.reload.team_id).to eq(team_without_owner.id)
    end
  end

  context 'with the "Todas" role (conversation_manage)' do
    before { restrict!(restricted, 'conversation_manage') }

    it 'takes a conversation from its owner, like before' do
      assign(restricted, owned, assignee_id: restricted.id)

      expect(response).to have_http_status(:success)
      expect(owned.reload.assignee_id).to eq(restricted.id)
    end

    it 'removes the owner, like before' do
      assign(restricted, owned, assignee_id: nil)

      expect(response).to have_http_status(:success)
      expect(owned.reload.assignee_id).to be_nil
    end
  end

  it 'lets an agent without custom role reassign any conversation, like before' do
    assign(colleague, owned, assignee_id: colleague.id)

    expect(response).to have_http_status(:success)
    expect(owned.reload.assignee_id).to eq(colleague.id)
  end

  it 'lets an administrator (the CRM integration token) assign and unassign any conversation, like before' do
    assign(admin, owned, assignee_id: colleague.id)
    expect(response).to have_http_status(:success)
    expect(owned.reload.assignee_id).to eq(colleague.id)

    assign(admin, owned, assignee_id: nil)
    expect(response).to have_http_status(:success)
    expect(owned.reload.assignee_id).to be_nil
  end
end
