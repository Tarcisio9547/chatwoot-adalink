require 'rails_helper'

RSpec.describe 'Conversation Participants API', type: :request do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:agent) { create(:user, account: account, role: :agent) }

  before do
    create(:inbox_member, inbox: conversation.inbox, user: agent)
  end

  # Quem pode mexer na lista: administrador, agente sem custom_role, custom_role com
  # conversation_manage ou o RESPONSÁVEL atual. Quem só enxerga a conversa (participante
  # ou restrito) não pode, senão se adicionaria numa conversa sem responsável e ficaria
  # com acesso mesmo depois de a roleta entregar o lead a outro corretor.
  describe 'who can change the participants' do
    let(:unassigned) { create(:conversation, account: account, inbox: conversation.inbox, assignee: nil) }
    let(:colleague) { create(:user, account: account, role: :agent) }
    let(:restricted) { create(:user, account: account, role: :agent) }
    let(:participants_url) do
      ->(target) { api_v1_account_conversation_participants_url(account_id: account.id, conversation_id: target.display_id) }
    end

    def restrict(user, permissions)
      role = create(:custom_role, account: account, permissions: permissions)
      AccountUser.find_by(user: user, account: account).update!(role: :agent, custom_role: role)
    end

    %w[conversation_participating_manage conversation_unassigned_manage].each do |permission|
      context "with the restricted visibility #{permission}" do
        before do
          create(:inbox_member, inbox: conversation.inbox, user: restricted)
          restrict(restricted, [permission])
        end

        it 'answers 401 when the restricted agent adds himself to an unassigned conversation, and adds nothing' do
          post participants_url.call(unassigned), params: { user_ids: [restricted.id] }, headers: restricted.create_new_auth_token, as: :json

          expect(response).to have_http_status(:unauthorized)
          expect(unassigned.conversation_participants.count).to eq(0)
        end

        it 'answers 401 on PUT and DELETE for the same conversation' do
          create(:conversation_participant, conversation: unassigned, account: account, user: colleague)

          put participants_url.call(unassigned), params: { user_ids: [colleague.id, restricted.id] }, headers: restricted.create_new_auth_token, as: :json
          expect(response).to have_http_status(:unauthorized)

          delete participants_url.call(unassigned), params: { user_ids: [colleague.id] }, headers: restricted.create_new_auth_token, as: :json
          expect(response).to have_http_status(:unauthorized)
          expect(unassigned.conversation_participants.pluck(:user_id)).to eq([colleague.id])
        end

        it 'answers 401 when the restricted agent cannot even see the conversation (POST)' do
          hidden = create(:conversation, account: account, inbox: create(:inbox, account: account), assignee: nil)

          post participants_url.call(hidden), params: { user_ids: [restricted.id] }, headers: restricted.create_new_auth_token, as: :json

          expect(response).to have_http_status(:unauthorized)
          expect(hidden.conversation_participants.count).to eq(0)
        end

        it 'answers 401 when a restricted PARTICIPANT tries to add other people' do
          create(:conversation_participant, conversation: conversation, account: account, user: restricted)

          post participants_url.call(conversation), params: { user_ids: [colleague.id] }, headers: restricted.create_new_auth_token, as: :json

          expect(response).to have_http_status(:unauthorized)
          expect(conversation.conversation_participants.pluck(:user_id)).to eq([restricted.id])
        end

        it 'still lets the restricted participant LIST the participants (read-only)' do
          create(:conversation_participant, conversation: conversation, account: account, user: restricted)

          get participants_url.call(conversation), headers: restricted.create_new_auth_token, as: :json

          expect(response).to have_http_status(:success)
        end

        it 'lets the restricted CURRENT ASSIGNEE add a colleague' do
          conversation.update!(assignee: restricted)

          post participants_url.call(conversation), params: { user_ids: [colleague.id] }, headers: restricted.create_new_auth_token, as: :json

          expect(response).to have_http_status(:success)
          expect(conversation.conversation_participants.pluck(:user_id)).to eq([colleague.id])
        end
      end
    end

    it 'lets an administrator change the participants of any conversation' do
      admin = create(:user, account: account, role: :administrator)

      post participants_url.call(unassigned), params: { user_ids: [colleague.id] }, headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(unassigned.conversation_participants.pluck(:user_id)).to eq([colleague.id])
    end

    it 'lets a custom role with conversation_manage ("Todas") change the participants' do
      create(:inbox_member, inbox: conversation.inbox, user: restricted)
      restrict(restricted, %w[conversation_manage])

      post participants_url.call(unassigned), params: { user_ids: [colleague.id] }, headers: restricted.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
    end
  end

  # user_ids que não é lista de inteiros nunca pode virar 500 nem mexer em nada.
  describe 'user_ids validation' do
    let(:url) { api_v1_account_conversation_participants_url(account_id: account.id, conversation_id: conversation.display_id) }
    let(:existing) { create(:user, account: account, role: :agent) }

    before { create(:conversation_participant, conversation: conversation, account: account, user: existing) }

    [
      ['a string', 'abc'],
      ['an object', { '0' => 1 }],
      ['a list with a word', [1, 'x']],
      ['a nested list', [[1]]],
      ['a list with null', [nil]],
      ['a list with an object', [{ 'id' => 1 }]],
      ['a list with a float', [1.5]]
    ].each do |label, value|
      it "answers 422 (never 500) on POST, PUT and DELETE when user_ids is #{label}, and changes nothing" do
        [:post, :put, :delete].each do |verb|
          public_send(verb, url, params: { user_ids: value }, headers: agent.create_new_auth_token, as: :json)

          expect(response).to have_http_status(:unprocessable_entity)
        end
        expect(conversation.conversation_participants.pluck(:user_id)).to eq([existing.id])
      end
    end

    it 'answers 422 when user_ids is missing on POST and DELETE too' do
      post url, params: {}, headers: agent.create_new_auth_token, as: :json
      expect(response).to have_http_status(:unprocessable_entity)

      delete url, params: {}, headers: agent.create_new_auth_token, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'does not blow up with an integer far beyond the id range (just ignores it)' do
      post url, params: { user_ids: [99_999_999_999_999_999_999] }, headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(conversation.conversation_participants.pluck(:user_id)).to eq([existing.id])
    end

    it 'accepts ids sent as digit strings (form-encoded clients)' do
      other = create(:user, account: account, role: :agent)

      post url, params: { user_ids: [other.id.to_s] }, headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(conversation.conversation_participants.pluck(:user_id)).to contain_exactly(existing.id, other.id)
    end

    it 'DELETE only removes participants that belong to the account (ignores foreign ids)' do
      foreign = create(:user, account: create(:account), role: :agent)

      delete url, params: { user_ids: [foreign.id, existing.id] }, headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(conversation.conversation_participants.count).to eq(0)
    end
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

      it 'refuses a call without user_ids and keeps the current participants (it must not mean an empty list)' do
        create(:conversation_participant, conversation: conversation, user: participant)

        put api_v1_account_conversation_participants_url(account_id: account.id, conversation_id: conversation.display_id),
            params: {},
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(conversation.conversation_participants.pluck(:user_id)).to eq([participant.id])
      end

      it 'removes everybody when the list is sent explicitly empty' do
        create(:conversation_participant, conversation: conversation, user: participant)

        put api_v1_account_conversation_participants_url(account_id: account.id, conversation_id: conversation.display_id),
            params: { user_ids: [] },
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.conversation_participants.count).to eq(0)
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
