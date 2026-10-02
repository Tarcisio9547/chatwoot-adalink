require 'rails_helper'

# O job de broadcast é enfileirado com o token de A quando A ainda é o responsável.
# Antes de executar, a conversa vai pra B e B manda uma mensagem. O payload é
# relido do banco na execução e traria a mensagem de B; A não pode recebê-la.
# rubocop:disable RSpec/DescribeClass -- cobre o job de upstream mais o
# override Enterprise::ActionCableBroadcastJob (prepend_mod_with); o
# comportamento testado e o conjunto, nao uma classe so.
describe 'ActionCableBroadcastJob role visibility on delayed delivery' do
  let!(:account) { create(:account) }
  let!(:agent_a) { create(:user, account: account, role: :agent) }
  let!(:agent_b) { create(:user, account: account, role: :agent) }
  let!(:setor_role) { create(:custom_role, account: account, permissions: %w[conversation_participating_manage]) }
  let!(:whatsapp_inbox) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox
  end
  let!(:conversation) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: agent_a) }

  before do
    create(:inbox_member, user: agent_a, inbox: whatsapp_inbox)
    create(:inbox_member, user: agent_b, inbox: whatsapp_inbox)
    AccountUser.find_by(user: agent_a, account: account).update(custom_role: setor_role)
    AccountUser.find_by(user: agent_b, account: account).update(custom_role: setor_role)
    conversation.inbox.reload
  end

  it 'does not deliver content created after A lost access to the conversation' do
    # O job "atrasado" foi originalmente disparado quando A ainda era
    # destinatario legitimo (ele era o assignee). Simulamos isso chamando
    # perform diretamente com o token de A, sem passar pelo enqueue real -
    # o ponto do teste e o PERFORM (que sempre releu do banco), nao o
    # enqueue.
    data = { id: conversation.display_id, account_id: account.id }

    # A conversa e reatribuida pra B DEPOIS do "disparo" do job (que so
    # tinha o token de A), e B manda uma mensagem nova - o cenario que o
    # job atrasado vai encontrar quando finalmente executar.
    conversation.update!(assignee: agent_b)
    new_message = create(:message, account: account, inbox: whatsapp_inbox, conversation: conversation,
                                   content: 'mensagem nova de B depois da troca', message_type: :outgoing)

    broadcasted = []
    allow(ActionCable.server).to receive(:broadcast) do |token, payload|
      broadcasted << [token, payload]
    end

    ActionCableBroadcastJob.perform_now([agent_a.pubsub_token], 'conversation.updated', data)

    a_broadcast = broadcasted.find { |token, _payload| token == agent_a.pubsub_token }
    expect(a_broadcast).to be_nil, 'A nao deveria receber conversation.updated depois de perder o acesso (so recebe assignee.changed)'

    # Confere que a mensagem nova de fato estaria no payload padrao (prova
    # que o cenario de vazamento existiria sem a correcao).
    expect(conversation.reload.push_event_data[:messages].first[:content]).to eq(new_message.content)
  end

  it 'still delivers assignee.changed to whoever lost access, but without messages' do
    data = { id: conversation.display_id, account_id: account.id }

    conversation.update!(assignee: agent_b)
    create(:message, account: account, inbox: whatsapp_inbox, conversation: conversation, content: 'mensagem nova de B', message_type: :outgoing)

    broadcasted = []
    allow(ActionCable.server).to receive(:broadcast) do |token, payload|
      broadcasted << [token, payload]
    end

    ActionCableBroadcastJob.perform_now([agent_a.pubsub_token], 'assignee.changed', data)

    a_broadcast = broadcasted.find { |token, _payload| token == agent_a.pubsub_token }
    expect(a_broadcast).not_to be_nil, 'A precisa continuar recebendo assignee.changed pra sumir a conversa da lista dele'

    _token, payload = a_broadcast
    expect(payload[:data]).not_to have_key(:messages)
  end

  it 'still delivers the full payload (including messages) to whoever can still see the conversation' do
    data = { id: conversation.display_id, account_id: account.id }
    new_message = create(:message, account: account, inbox: whatsapp_inbox, conversation: conversation, content: 'ainda visivel',
                                   message_type: :outgoing)

    broadcasted = []
    allow(ActionCable.server).to receive(:broadcast) do |token, payload|
      broadcasted << [token, payload]
    end

    ActionCableBroadcastJob.perform_now([agent_a.pubsub_token], 'conversation.updated', data)

    _token, payload = broadcasted.find { |token, _payload| token == agent_a.pubsub_token }
    expect(payload[:data][:messages].first[:content]).to eq(new_message.content)
  end

  context 'when the inbox is not Channel::Whatsapp' do
    let!(:other_inbox) { create(:inbox, account: account) }
    let!(:other_conversation) { create(:conversation, account: account, inbox: other_inbox, assignee: agent_a) }

    before { create(:inbox_member, user: agent_a, inbox: other_inbox) }

    it 'keeps delivering the full payload (current behaviour, unchanged)' do
      data = { id: other_conversation.display_id, account_id: account.id }
      other_conversation.update!(assignee: agent_b)
      new_message = create(:message, account: account, inbox: other_inbox, conversation: other_conversation, content: 'sem filtro',
                                     message_type: :outgoing)

      broadcasted = []
      allow(ActionCable.server).to receive(:broadcast) do |token, payload|
        broadcasted << [token, payload]
      end

      ActionCableBroadcastJob.perform_now([agent_a.pubsub_token], 'conversation.updated', data)

      _token, payload = broadcasted.find { |token, _payload| token == agent_a.pubsub_token }
      expect(payload[:data][:messages].first[:content]).to eq(new_message.content)
    end
  end

  # O override so pode custar consultas extras quando o evento e de conversa
  # E a caixa e WhatsApp. O resto dos broadcasts (a maioria) tem que custar o
  # mesmo que o job upstream.
  describe 'query count' do
    let!(:other_inbox) { create(:inbox, account: account) }
    let!(:other_conversation) { create(:conversation, account: account, inbox: other_inbox, assignee: agent_a) }
    let(:members) { [agent_a.pubsub_token] }

    before do
      create(:inbox_member, user: agent_a, inbox: other_inbox)
      allow(ActionCable.server).to receive(:broadcast)
    end

    def count_queries(sql_filter: nil, &)
      count = 0
      counter = lambda do |_name, _started, _finished, _unique_id, payload|
        next if payload[:name].in?(%w[SCHEMA CACHE])
        next if sql_filter && payload[:sql] !~ sql_filter

        count += 1
      end
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
      count
    end

    # perform do job upstream, ignorando o override prepend
    def upstream_perform(event_name, data)
      ActionCableBroadcastJob.new.method(:perform).super_method.call(members, event_name, data)
    end

    def override_perform(event_name, data)
      ActionCableBroadcastJob.new.perform(members, event_name, data)
    end

    it 'adds no queries to a conversation event of another inbox' do
      data = other_conversation.push_event_data.merge(account_id: account.id)
      upstream_perform('conversation.updated', data)

      expect(count_queries { override_perform('conversation.updated', data) })
        .to eq(count_queries { upstream_perform('conversation.updated', data) })
    end

    it 'adds no queries to events that are not conversation events' do
      data = { id: conversation.display_id, account_id: account.id }

      expect(count_queries { override_perform('message.created', data) }).to eq(0)
    end

    it 'adds a single lightweight query when the payload does not carry the channel' do
      data = { id: other_conversation.display_id, account_id: account.id }
      upstream_perform('conversation.updated', data)

      expect(count_queries { override_perform('conversation.updated', data) })
        .to eq(count_queries { upstream_perform('conversation.updated', data) } + 1)
    end

    it 'loads the conversation once on a WhatsApp conversation event' do
      data = conversation.push_event_data.merge(account_id: account.id)
      override_perform('conversation.updated', data)

      conversation_selects = count_queries(sql_filter: /FROM "conversations"/) { override_perform('conversation.updated', data) }

      expect(conversation_selects).to eq(1)
    end
  end
end
# rubocop:enable RSpec/DescribeClass
