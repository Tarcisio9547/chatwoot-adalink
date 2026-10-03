require 'rails_helper'

# Numa conversa de outro canal (não WhatsApp) os listeners de participação não
# podem custar consulta além do upstream. O ParticipationListener roda no job
# assíncrono, com a conversa recarregada (sem a caixa carregada), junto dos outros
# listeners na ordem real; a limpeza roda síncrona, antes do ActionCableListener.
# rubocop:disable RSpec/DescribeClass -- compara o custo dos listeners com a base.
describe 'participation listeners on a non-WhatsApp conversation (query count)' do
  let!(:account) { create(:account) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:agent_a) { create(:user, account: account, role: :agent) }
  let!(:agent_b) { create(:user, account: account, role: :agent) }
  let(:participation_listener) { ParticipationListener.instance }
  let(:cleanup_listener) { WhatsappParticipationCleanupListener.instance }
  let(:async_dispatcher) { Rails.configuration.dispatcher.async_dispatcher }

  before do
    [agent_a, agent_b].each { |user| create(:inbox_member, user: user, inbox: inbox) }
    allow(Rails.configuration.dispatcher).to receive(:dispatch)
  end

  def count_queries(&)
    count = 0
    counter = ->(_name, _started, _finished, _id, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA CACHE]) }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
    count
  end

  # Os dados que o EventDispatcherJob recebe: o payload do model passando pelo
  # AsyncDispatcher#dispatch real, com a conversa recarregada como o job faz.
  def dispatched_data(conversation)
    data = nil
    allow(Rails.configuration.dispatcher).to receive(:dispatch) { |name, _timestamp, payload| data = payload if name == 'assignee.changed' }
    conversation.update!(assignee: agent_a)
    job_args = nil
    allow(EventDispatcherJob).to receive(:perform_later) { |*args| job_args = args }
    async_dispatcher.dispatch('assignee.changed', Time.zone.now, data)
    job_args.last.merge(conversation: Conversation.find(conversation.id))
  end

  def new_conversation(assignee: nil)
    create(:conversation, account: account, inbox: inbox, assignee: assignee)
  end

  it 'adds no query to the async dispatch of assignee.changed compared to the upstream ParticipationListener' do
    upstream = participation_listener.method(:assignee_changed).super_method
    warm_up = dispatched_data(new_conversation)
    base_data = dispatched_data(new_conversation)
    enterprise_data = dispatched_data(new_conversation)
    async_dispatcher.publish_event('assignee.changed', Time.zone.now, warm_up)

    allow(participation_listener).to receive(:assignee_changed) { |event| upstream.call(event) }
    base = count_queries { async_dispatcher.publish_event('assignee.changed', Time.zone.now, base_data) }
    allow(participation_listener).to receive(:assignee_changed).and_call_original
    with_listener = count_queries { async_dispatcher.publish_event('assignee.changed', Time.zone.now, enterprise_data) }

    expect(with_listener).to eq(base)
  end

  it 'adds no query to the cleanup listener on another channel beyond what the next sync listener loads anyway' do
    changed = { 'assignee_id' => [agent_b.id, agent_a.id] }
    first = dispatched_data(new_conversation(assignee: agent_b)).merge(changed_attributes: changed)
    second = dispatched_data(new_conversation(assignee: agent_b)).merge(changed_attributes: changed)
    next_listener_loads = ->(data) { data[:conversation].then { |conversation| [conversation.account, conversation.inbox] } }

    base = count_queries { next_listener_loads.call(first) }
    with_listener = count_queries do
      cleanup_listener.assignee_changed(Events::Base.new(:assignee_changed, Time.zone.now, second))
      next_listener_loads.call(second)
    end

    expect(with_listener).to eq(base)
  end
end
# rubocop:enable RSpec/DescribeClass
