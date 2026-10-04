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

  describe 'participant_ids in the payload (the browser filter needs it to keep the conversation in the list)' do
    before { create(:conversation_participant, conversation: conversation, account: account, user: participant) }

    it 'comes in the conversations list' do
      get "/api/v1/accounts/#{account.id}/conversations", headers: admin.create_new_auth_token, as: :json

      item = response.parsed_body['data']['payload'].find { |entry| entry['id'] == conversation.display_id }
      expect(item['participant_ids']).to contain_exactly(participant.id)
    end

    it 'comes in the single conversation response' do
      get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}", headers: admin.create_new_auth_token, as: :json

      expect(response.parsed_body['participant_ids']).to contain_exactly(participant.id)
    end

    it 'comes in the realtime push payload' do
      expect(conversation.push_event_data[:participant_ids]).to contain_exactly(participant.id)
    end

    it 'is an empty list when nobody participates' do
      ConversationParticipant.where(conversation: conversation).destroy_all

      expect(conversation.push_event_data[:participant_ids]).to eq([])
    end
  end
end
