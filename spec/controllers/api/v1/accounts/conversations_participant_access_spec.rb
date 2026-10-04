require 'rails_helper'

# Regra do produto: quem é adicionado como participante de uma conversa passa a
# VER a conversa na lista e pode RESPONDER, seja qual for a visibilidade dele
# ("Minhas" = conversation_participating_manage, "Não atribuídas" =
# conversation_unassigned_manage, "Todas" = conversation_manage). Quem não tem
# vínculo continua sem ver nada.
describe 'Conversations API: acesso do participante', type: :request do
  let!(:account) { create(:account) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:owner) { create(:user, account: account, role: :agent) }
  let!(:participant) { create(:user, account: account, role: :agent) }
  let!(:stranger) { create(:user, account: account, role: :agent) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  # Conversa atribuída a OUTRA pessoa: o caso que a visibilidade restrita barrava.
  let!(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: owner) }
  let(:reply) { 'resposta do participante' }

  def listed_ids(user)
    get "/api/v1/accounts/#{account.id}/conversations", headers: user.create_new_auth_token, as: :json
    response.parsed_body['data']['payload'].pluck('id')
  end

  def show(user)
    get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}", headers: user.create_new_auth_token, as: :json
  end

  def reply_as(user)
    post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages",
         headers: user.create_new_auth_token, params: { content: reply }, as: :json
  end

  def give_role(user, permissions)
    role = create(:custom_role, account: account, permissions: permissions)
    AccountUser.find_by(user: user, account: account).update!(role: :agent, custom_role: role)
  end

  {
    'Minhas' => %w[conversation_participating_manage],
    'Não atribuídas' => %w[conversation_unassigned_manage]
  }.each do |label, permissions|
    context "with the \"#{label}\" visibility" do
      before do
        [participant, stranger].each do |user|
          create(:inbox_member, user: user, inbox: inbox)
          give_role(user, permissions)
        end
        create(:conversation_participant, conversation: conversation, account: account, user: participant)
      end

      it 'lists the conversation for the participant' do
        expect(listed_ids(participant)).to include(conversation.display_id)
      end

      it 'does not list the conversation for someone without a link to it' do
        expect(listed_ids(stranger)).not_to include(conversation.display_id)
      end

      it 'lets the participant open the conversation (show)' do
        show(participant)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['id']).to eq(conversation.display_id)
      end

      it 'keeps barring someone without a link to it (show)' do
        show(stranger)

        expect(response).to have_http_status(:unauthorized)
      end

      it 'lets the participant reply' do
        reply_as(participant)

        expect(response).to have_http_status(:ok)
        expect(conversation.messages.where(content: reply, message_type: :outgoing).count).to eq(1)
      end

      it 'keeps barring someone without a link to it from replying' do
        reply_as(stranger)

        expect(response).to have_http_status(:unauthorized)
        expect(conversation.messages.where(content: reply)).to be_empty
      end

      it 'stops listing and showing the conversation once the participant is removed' do
        ConversationParticipant.where(conversation: conversation, user: participant).destroy_all

        expect(listed_ids(participant)).not_to include(conversation.display_id)
        show(participant)
        expect(response).to have_http_status(:unauthorized)
      end

      it 'does not open the other conversations of the same colleague to the participant' do
        other = create(:conversation, account: account, inbox: inbox, assignee: owner)

        expect(listed_ids(participant)).not_to include(other.display_id)
        get "/api/v1/accounts/#{account.id}/conversations/#{other.display_id}", headers: participant.create_new_auth_token, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  context 'when the participant is not a member of the inbox (e.g. a manager)' do
    before do
      give_role(participant, %w[conversation_participating_manage])
      create(:conversation_participant, conversation: conversation, account: account, user: participant)
    end

    it 'lists, opens and replies' do
      expect(listed_ids(participant)).to include(conversation.display_id)

      show(participant)
      expect(response).to have_http_status(:ok)

      reply_as(participant)
      expect(response).to have_http_status(:ok)
    end
  end

  # O Chatwoot faz de todo responsável um participante. Se o ex-responsável (de qualquer canal,
  # não só WhatsApp) continuasse na lista, um agente de visão restrita que perdeu a conversa
  # para a roleta seguiria vendo e respondendo nela para sempre.
  describe 'ex-assignee after A -> B on an inbox that is not WhatsApp (real callbacks)' do
    let!(:new_owner) { create(:user, account: account, role: :agent) }
    let!(:fresh) { create(:conversation, account: account, inbox: inbox, assignee: nil) }

    %w[conversation_participating_manage conversation_unassigned_manage].each do |permission|
      context "with the restricted visibility #{permission}" do
        before do
          [owner, new_owner].each { |user| create(:inbox_member, user: user, inbox: inbox) }
          give_role(owner, [permission])
          perform_enqueued_jobs { fresh.update!(assignee: owner) }
        end

        it 'becomes a participant while he is the assignee (upstream behaviour)' do
          expect(fresh.conversation_participants.pluck(:user_id)).to eq([owner.id])
        end

        it 'stops seeing, opening and answering the conversation once it goes to someone else' do
          perform_enqueued_jobs { fresh.update!(assignee: new_owner) }

          expect(fresh.reload.conversation_participants.pluck(:user_id)).to eq([new_owner.id])
          expect(listed_ids(owner)).not_to include(fresh.display_id)
          get "/api/v1/accounts/#{account.id}/conversations/#{fresh.display_id}", headers: owner.create_new_auth_token, as: :json
          expect(response).to have_http_status(:unauthorized)
          post "/api/v1/accounts/#{account.id}/conversations/#{fresh.display_id}/messages",
               headers: owner.create_new_auth_token, params: { content: reply }, as: :json
          expect(response).to have_http_status(:unauthorized)
        end

        it 'keeps a participant added by hand when the conversation changes hands' do
          manual = create(:user, account: account, role: :agent)
          create(:conversation_participant, conversation: fresh, account: account, user: manual)

          perform_enqueued_jobs { fresh.update!(assignee: new_owner) }

          expect(fresh.reload.conversation_participants.pluck(:user_id)).to contain_exactly(manual.id, new_owner.id)
        end
      end
    end
  end

  # O CRM adiciona o gestor do corretor como participante de uma conversa do WhatsApp Pessoal
  # (caixa Channel::Api, wa-pessoal-mark-work / wa-classifier-confirm, com o token de
  # administrador da conta). O gestor nunca foi responsável: a limpeza do responsável anterior
  # (todos os canais) só remove o responsável anterior e nunca tira o gestor, seja ele membro da
  # caixa pessoal do subordinado (hierarquia do CRM) ou não.
  describe 'manager added by the CRM to a personal WhatsApp conversation (real callbacks)' do
    let!(:personal_inbox) { create(:inbox, account: account, channel: create(:channel_api, account: account)) }
    let!(:broker) { create(:user, account: account, role: :agent) }
    let!(:new_broker) { create(:user, account: account, role: :agent) }
    let!(:personal_conversation) { create(:conversation, account: account, inbox: personal_inbox, assignee: broker) }
    let!(:manager) { create(:user, account: account, role: :agent) }

    def show_as(user)
      get "/api/v1/accounts/#{account.id}/conversations/#{personal_conversation.display_id}", headers: user.create_new_auth_token, as: :json
    end

    before do
      stub_request(:post, 'http://example.com/') # webhook da caixa Channel::Api (conversation_updated)
      [broker, new_broker].each { |user| create(:inbox_member, inbox: personal_inbox, user: user) }
      create(:conversation_participant, conversation: personal_conversation, account: account, user: broker)
    end

    it 'adds the manager with the administrator token and he can open the conversation' do
      post "/api/v1/accounts/#{account.id}/conversations/#{personal_conversation.display_id}/participants",
           params: { user_ids: [manager.id] }, headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:success)

      show_as(manager)
      expect(response).to have_http_status(:ok)
    end

    [nil, 'conversation_participating_manage', 'conversation_unassigned_manage'].each do |permission|
      [true, false].each do |member|
        it "keeps the manager (#{permission || 'no custom role'}, #{member ? 'member' : 'not a member'} of the inbox) when the conversation changes hands" do
          give_role(manager, [permission]) if permission
          create(:inbox_member, inbox: personal_inbox, user: manager) if member
          create(:conversation_participant, conversation: personal_conversation, account: account, user: manager)

          perform_enqueued_jobs { personal_conversation.update!(assignee: new_broker) }

          show_as(manager)
          expect(response).to have_http_status(:ok)
          expect(personal_conversation.reload.conversation_participants.pluck(:user_id)).to contain_exactly(manager.id, new_broker.id)
        end
      end
    end

    it 'removes only the previous assignee when it changes hands' do
      give_role(broker, %w[conversation_unassigned_manage])

      perform_enqueued_jobs { personal_conversation.update!(assignee: new_broker) }

      expect(personal_conversation.reload.conversation_participants.pluck(:user_id)).to eq([new_broker.id])
      show_as(broker)
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'participant_ids in the payload (the browser filter needs it to keep the conversation in the list)' do
    before { create(:conversation_participant, conversation: conversation, account: account, user: participant) }

    it 'comes in the conversations list' do
      get "/api/v1/accounts/#{account.id}/conversations", headers: admin.create_new_auth_token, as: :json

      item = response.parsed_body['data']['payload'].find { |entry| entry['id'] == conversation.display_id }
      expect(item['participant_ids']).to contain_exactly(participant.id)
    end

    it 'comes in the advanced filter response' do
      post "/api/v1/accounts/#{account.id}/conversations/filter",
           headers: admin.create_new_auth_token,
           params: { payload: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['open'], query_operator: nil }] },
           as: :json

      expect(response).to have_http_status(:ok)
      item = response.parsed_body['payload'].find { |entry| entry['id'] == conversation.display_id }
      expect(item['participant_ids']).to contain_exactly(participant.id)
    end

    it 'comes in the single conversation response' do
      get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}", headers: admin.create_new_auth_token, as: :json

      expect(response.parsed_body['participant_ids']).to contain_exactly(participant.id)
    end

    it 'comes in the realtime payload sent to agents (and only there: the common push payload has none)' do
      expect(conversation.agent_push_event_data[:participant_ids]).to contain_exactly(participant.id)
      expect(conversation.push_event_data).not_to have_key(:participant_ids)
    end

    it 'is an empty list when nobody participates' do
      ConversationParticipant.where(conversation: conversation).destroy_all

      expect(conversation.agent_push_event_data[:participant_ids]).to eq([])
    end
  end
end
