require 'rails_helper'

# participant_ids é dado de agente: nunca no payload comum (push_event_data), que também
# alimenta o contato (widget) e os webhooks externos/AgentBot (webhook_data). Só no
# payload de agente (agent_push_event_data).
# rubocop:disable RSpec/DescribeMethod, RSpec/SpecFilePathFormat -- cobre a fronteira de audiência do presenter.
describe Conversations::EventDataPresenter, 'participant_ids audience' do
  let!(:account) { create(:account) }
  let!(:agent) { create(:user, account: account, role: :agent) }
  let!(:conversation) { create(:conversation, account: account, assignee: agent) }

  before { create(:conversation_participant, conversation: conversation, account: account, user: agent) }

  it 'keeps participant_ids out of the common push payload' do
    expect(conversation.push_event_data).not_to have_key(:participant_ids)
    expect(described_class.new(conversation).push_data).not_to have_key(:participant_ids)
  end

  it 'keeps participant_ids out of the webhook payload (external webhooks, agent bots)' do
    expect(conversation.webhook_data).not_to have_key(:participant_ids)
    expect(conversation.webhook_data.to_json).not_to include('participant_ids')
  end

  it 'adds participant_ids only to the agent payload' do
    expect(conversation.agent_push_event_data[:participant_ids]).to contain_exactly(agent.id)
  end

  it 'keeps the agent payload equal to the common one plus participant_ids' do
    expect(conversation.agent_push_event_data.except(:participant_ids)).to eq(conversation.push_event_data)
  end

  it 'does not put participant_ids in the payload the webhook listener sends' do
    webhook = create(:webhook, account: account, inbox: conversation.inbox, url: 'https://example.com/hook', subscriptions: ['conversation_updated'])
    sent_payloads = []
    allow(WebhookJob).to receive(:perform_later) { |_url, payload, *_rest| sent_payloads << payload }

    event = Events::Base.new('conversation.updated', Time.zone.now, conversation: conversation, changed_attributes: {})
    WebhookListener.instance.conversation_updated(event)

    expect(webhook).to be_persisted
    expect(sent_payloads).not_to be_empty
    expect(sent_payloads.to_json).not_to include('participant_ids')
  end
end
# rubocop:enable RSpec/DescribeMethod, RSpec/SpecFilePathFormat
