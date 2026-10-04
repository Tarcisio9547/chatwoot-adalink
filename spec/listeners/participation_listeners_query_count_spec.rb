require 'rails_helper'

# Custo dos listeners de participação, que agora valem em TODOS os canais. O
# ParticipationListener roda no job assíncrono, com a conversa recarregada (sem a caixa
# carregada), junto dos outros listeners na ordem real; a limpeza roda síncrona, antes do
# ActionCableListener. A primeira atribuição não custa consulta nenhuma na limpeza; a troca
# de responsável paga um lock de linha e a remoção do participante anterior.
# rubocop:disable RSpec/DescribeClass -- compara o custo dos listeners com a base.
describe 'participation listeners (query count)' do
  let!(:account) { create(:account) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:agent_a) { create(:user, account: account, role: :agent) }
  let!(:agent_b) { create(:user, account: account, role: :agent) }
  let(:participation_listener) { ParticipationListener.instance }
  let(:cleanup_listener) { ParticipationCleanupListener.instance }
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

  it 'costs the async dispatch of assignee.changed only the row lock over the upstream ParticipationListener' do
    upstream = participation_listener.method(:assignee_changed).super_method
    warm_up = dispatched_data(new_conversation)
    base_data = dispatched_data(new_conversation)
    enterprise_data = dispatched_data(new_conversation)
    async_dispatcher.publish_event('assignee.changed', Time.zone.now, warm_up)

    allow(participation_listener).to receive(:assignee_changed) { |event| upstream.call(event) }
    base = count_queries { async_dispatcher.publish_event('assignee.changed', Time.zone.now, base_data) }
    allow(participation_listener).to receive(:assignee_changed).and_call_original
    with_listener = count_queries { async_dispatcher.publish_event('assignee.changed', Time.zone.now, enterprise_data) }

    # transação (BEGIN/COMMIT) + SELECT ... FOR NO KEY UPDATE da conversa
    expect(with_listener - base).to be_between(1, 3)
  end

  it 'runs no query in the cleanup on the first assignment (no previous assignee), on any channel' do
    data = dispatched_data(new_conversation).merge(changed_attributes: { 'assignee_id' => [nil, agent_a.id] })

    expect(count_queries { cleanup_listener.assignee_changed(Events::Base.new(:assignee_changed, Time.zone.now, data)) }).to eq(0)
  end

  it 'costs a reassignment on another channel a bounded number of queries in the cleanup' do
    conversation = new_conversation(assignee: agent_b)
    conversation.conversation_participants.create!(user: agent_a)
    data = dispatched_data(conversation).merge(changed_attributes: { 'assignee_id' => [agent_a.id, agent_b.id] })
    conversation.update!(assignee: agent_b)

    queries = count_queries { cleanup_listener.assignee_changed(Events::Base.new(:assignee_changed, Time.zone.now, data)) }

    # transação + lock da conversa + leitura e remoção do participante anterior
    expect(queries).to be <= 6
    expect(conversation.reload.conversation_participants.pluck(:user_id)).not_to include(agent_a.id)
  end
end
# rubocop:enable RSpec/DescribeClass
