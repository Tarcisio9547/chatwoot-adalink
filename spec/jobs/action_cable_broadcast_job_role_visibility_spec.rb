require 'rails_helper'

# Adalink: correcao do juiz cego (rodada 3, item 2, BAIXA/MEDIA) - job
# atrasado entrega a quem perdeu a conversa dados de DEPOIS da troca.
#
# Cenario do teste: ActionCableBroadcastJob e enfileirado (mas nao
# executado) com o token de A como destinatario de um conversation.updated,
# no momento em que A ainda era o responsavel. Antes do job rodar, a
# conversa e reatribuida pra B e B manda uma mensagem nova. So entao o job
# executa. Como o job releu a conversa do banco (prepare_broadcast_data),
# o payload padrao incluiria a mensagem nova de B - o teste confere que A
# NAO recebe esse conteudo.
describe 'ActionCableBroadcastJob role visibility on delayed delivery (item 2)' do
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
end
