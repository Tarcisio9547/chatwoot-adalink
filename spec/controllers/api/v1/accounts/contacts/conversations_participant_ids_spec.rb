require 'rails_helper'

# participant_ids vai em toda conversa devolvida ao agente (lista, filtro, show, conversas do contato).
# Não pode virar uma consulta por conversa: o ConversationFinder, o FilterService e as conversas do
# contato pré-carregam os participantes.
RSpec.describe 'GET /api/v1/accounts/{account.id}/contacts/{id}/conversations (participant_ids)', type: :request do
  let!(:account) { create(:account) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:contact) { create(:contact, account: account) }
  let!(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }

  def make_conversation(participants: 2)
    conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
    participants.times { create(:conversation_participant, conversation: conversation, account: account, user: create(:user, account: account)) }
    conversation
  end

  def fetch
    get "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/conversations", headers: admin.create_new_auth_token, as: :json
  end

  def participant_selects
    selects = []
    counter = lambda do |_name, _started, _finished, _id, payload|
      selects << payload[:sql] if payload[:sql].include?('FROM "conversation_participants"')
    end
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { yield }
    selects
  end

  it 'brings the participant_ids of each conversation' do
    conversation = make_conversation(participants: 2)

    fetch

    item = response.parsed_body['payload'].find { |entry| entry['id'] == conversation.display_id }
    expect(item['participant_ids'].size).to eq(2)
  end

  it 'loads the participants of all the conversations with a single query, not one per conversation' do
    3.times { make_conversation }

    selects = participant_selects { fetch }

    expect(response.parsed_body['payload'].size).to eq(3)
    expect(selects.size).to eq(1)
  end
end
