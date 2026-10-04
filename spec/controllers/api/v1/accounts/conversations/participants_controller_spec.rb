require 'rails_helper'

RSpec.describe 'Conversation Participants API', type: :request do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:agent) { create(:user, account: account, role: :agent) }

  before do
    create(:inbox_member, inbox: conversation.inbox, user: agent)
  end

  describe 'GET /api/v1/accounts/{account.id}/conversations/<id>/paricipants' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get api_v1_account_conversation_participants_url(account_id: account.id, conversation_id: conversation.display_id)
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user with access to the conversation' do
      let(:participant1) { create(:user, account: account, role: :agent) }
      let(:participant2) { create(:user, account: account, role: :agent) }

      before do
        create(:inbox_member, inbox: conversation.inbox, user: participant1)
        create(:inbox_member, inbox: conversation.inbox, user: participant2)
      end

      it 'returns all the partipants for the conversation' do
        create(:conversation_participant, conversation: conversation, user: participant1)
        create(:conversation_participant, conversation: conversation, user: participant2)
        get api_v1_account_conversation_participants_url(account_id: account.id, conversation_id: conversation.display_id),
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(response.body).to include(participant1.email)
        expect(response.body).to include(participant2.email)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/conversations/<id>/participants' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post api_v1_account_conversation_participants_url(account_id: account.id, conversation_id: conversation.display_id)
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:participant) { create(:user, account: account, role: :agent) }

      before do
        create(:inbox_member, inbox: conversation.inbox, user: participant)
      end

      it 'creates a new participants when its authorized agent' do
        params = { user_ids: [participant.id] }

        expect(conversation.conversation_participants.count).to eq(0)
        post api_v1_account_conversation_participants_url(account_id: account.id, conversation_id: conversation.display_id),
             params: params,
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.body).to include(participant.email)
        expect(conversation.conversation_participants.count).to eq(1)
      end

      it 'adds an account agent who is not a member of the inbox' do
        outsider = create(:user, account: account, role: :agent)

        post api_v1_account_conversation_participants_url(account_id: account.id, conversation_id: conversation.display_id),
             params: { user_ids: [outsider.id] },
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.conversation_participants.pluck(:user_id)).to eq([outsider.id])
      end

      it 'ignores a user_id that belongs to another account' do
        foreign_user = create(:user, account: create(:account), role: :agent)

        post api_v1_account_conversation_participants_url(account_id: account.id, conversation_id: conversation.display_id),
             params: { user_ids: [participant.id, foreign_user.id] },
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.conversation_participants.pluck(:user_id)).to eq([participant.id])
        expect(response.body).not_to include(foreign_user.email)
      end

      it 'ignores a user_id that does not exist' do
        post api_v1_account_conversation_participants_url(account_id: account.id, conversation_id: conversation.display_id),
             params: { user_ids: [0] },
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.conversation_participants.count).to eq(0)
      end
    end
  end

  describe 'PUT /api/v1/accounts/{account.id}/conversations/<id>/participants' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        put api_v1_account_conversation_participants_url(account_id: account.id, conversation_id: conversation.display_id)
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:participant) { create(:user, account: account, role: :agent) }
      let(:participant_to_be_added) { create(:user, account: account, role: :agent) }
      let(:participant_to_be_removed) { create(:user, account: account, role: :agent) }

      before do
        create(:inbox_member, inbox: conversation.inbox, user: participant)
        create(:inbox_member, inbox: conversation.inbox, user: participant_to_be_added)
        create(:inbox_member, inbox: conversation.inbox, user: participant_to_be_removed)
      end

      it 'updates participants when its authorized agent' do
        params = { user_ids: [participant.id, participant_to_be_added.id] }
        create(:conversation_participant, conversation: conversation, user: participant)
        create(:conversation_participant, conversation: conversation, user: participant_to_be_removed)

        expect(conversation.conversation_participants.count).to eq(2)
        put api_v1_account_conversation_participants_url(account_id: account.id, conversation_id: conversation.display_id),
            params: params,
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(response.body).to include(participant.email)
        expect(response.body).to include(participant_to_be_added.email)
        expect(conversation.conversation_participants.count).to eq(2)
      end

      it 'does not add a user_id that belongs to another account, and still applies the rest of the update' do
        foreign_user = create(:user, account: create(:account), role: :agent)
        create(:conversation_participant, conversation: conversation, user: participant)
        create(:conversation_participant, conversation: conversation, user: participant_to_be_removed)

        put api_v1_account_conversation_participants_url(account_id: account.id, conversation_id: conversation.display_id),
            params: { user_ids: [participant.id, participant_to_be_added.id, foreign_user.id] },
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.conversation_participants.pluck(:user_id)).to contain_exactly(participant.id, participant_to_be_added.id)
      end
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/conversations/<id>/participants' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        delete api_v1_account_conversation_participants_url(account_id: account.id, conversation_id: conversation.display_id)
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:participant) { create(:user, account: account, role: :agent) }

      before do
        create(:inbox_member, inbox: conversation.inbox, user: participant)
      end

      it 'deletes participants when its authorized agent' do
        params = { user_ids: [participant.id] }
        create(:conversation_participant, conversation: conversation, user: participant)

        expect(conversation.conversation_participants.count).to eq(1)
        delete api_v1_account_conversation_participants_url(account_id: account.id, conversation_id: conversation.display_id),
               params: params,
               headers: agent.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.conversation_participants.count).to eq(0)
      end
    end
  end
end
