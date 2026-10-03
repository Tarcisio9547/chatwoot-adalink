require 'rails_helper'

# O assignee.changed de uma conversa WhatsApp leva channel_type no payload do job
# (o ParticipationListener decide pela presença da chave, sem consulta). O payload
# de outras caixas e o de qualquer outro evento ficam idênticos ao upstream.
# rubocop:disable RSpec/DescribeMethod -- cobre so o enriquecimento do payload em #dispatch.
describe AsyncDispatcher, 'channel_type payload' do
  subject(:dispatcher) { described_class.new }

  let(:account) { create(:account) }
  let(:whatsapp_inbox) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox
  end
  let(:whatsapp_conversation) { create(:conversation, account: account, inbox: whatsapp_inbox) }
  let(:other_conversation) { create(:conversation, account: account, inbox: create(:inbox, account: account)) }
  let(:timestamp) { Time.zone.now }

  it 'adds channel_type to assignee.changed of a WhatsApp conversation' do
    data = { conversation: whatsapp_conversation, changed_attributes: { 'assignee_id' => [nil, 1] } }

    expect(EventDispatcherJob).to receive(:perform_later)
      .with('assignee.changed', timestamp, data.merge(channel_type: 'Channel::Whatsapp')).once

    dispatcher.dispatch('assignee.changed', timestamp, data)
  end

  it 'keeps assignee.changed of another channel identical to upstream (no channel_type key)' do
    data = { conversation: other_conversation, changed_attributes: { 'assignee_id' => [nil, 1] } }

    expect(EventDispatcherJob).to receive(:perform_later).with('assignee.changed', timestamp, data).once

    dispatcher.dispatch('assignee.changed', timestamp, data)
  end

  it 'keeps the other events of a WhatsApp conversation identical to upstream' do
    data = { conversation: whatsapp_conversation }

    expect(EventDispatcherJob).to receive(:perform_later).with('conversation.created', timestamp, data).once

    dispatcher.dispatch('conversation.created', timestamp, data)
  end
end
# rubocop:enable RSpec/DescribeMethod
