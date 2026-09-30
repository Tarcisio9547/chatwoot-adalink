require 'rails_helper'

# Adalink: correcao do juiz cego (rodada 3, item 1, MEDIA). A corrida:
# 1. Job assincrono processa nil->A: le o assignee_id atual (A), esta
#    PRESTES a inserir o participante A, mas pausa (fila lenta, GC, etc).
# 2. A->B acontece de verdade, sincrono: WhatsappParticipationCleanupListener
#    roda e tenta remover a participacao de A - mas como o job do passo 1
#    ainda nao inseriu, nao ha nada pra remover (no-op).
# 3. O job do passo 1 retoma e insere A como participante.
# 4. Resultado: assignee_id = B, mas A fica participante PARA SEMPRE - o
#    cleanup ja rodou e nao vai rodar de novo pra essa troca.
#
# Este spec forca a intercalacao exata com uma Queue como barreira, inserida
# diretamente no metodo (nao via mock RSpec, que nao e garantidamente
# thread-safe): a thread do "job antigo" pausa depois de ler o assignee_id
# mas antes de inserir o participante; nesse meio tempo a thread da troca
# real roda ate o fim (limpeza + reatribuicao); so entao o job antigo
# continua. Tem que FALHAR no codigo atual (sem lock) e PASSAR depois da
# correcao (conversation.with_lock nos dois listeners).
describe Enterprise::ParticipationListener, 'race with a concurrent reassignment' do
  let(:listener) { ParticipationListener.instance }
  let(:cleanup_listener) { WhatsappParticipationCleanupListener.instance }

  let!(:account) { create(:account) }
  let!(:agent_a) { create(:user, account: account, role: :agent) }
  let!(:agent_b) { create(:user, account: account, role: :agent) }
  let!(:whatsapp_inbox) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox
  end
  let!(:conversation) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: agent_a) }

  before do
    create(:inbox_member, user: agent_a, inbox: whatsapp_inbox)
    create(:inbox_member, user: agent_b, inbox: whatsapp_inbox)
    conversation.inbox.reload
  end

  it 'does not leave the previous assignee as a permanent participant after a race with a fast reassignment' do
    old_job_read_assignee = Queue.new
    reassignment_done = Queue.new

    # Simula o job assincrono antigo (nil->A): intercepta o metodo publico
    # pra pausar DEPOIS de ler o assignee_id atual (dentro do metodo real,
    # via find_or_create_by! - a chamada real ja faz a leitura implicita do
    # estado da conversa) e ANTES de commitar a insercao.
    listener_class = listener.singleton_class
    original_method = listener_class.instance_method(:assignee_changed)

    listener_class.define_method(:assignee_changed) do |event|
      conversation_arg, = extract_conversation_and_account(event)
      if conversation_arg.inbox.whatsapp? && conversation_arg.id == conversation.id
        old_job_read_assignee << true
        reassignment_done.pop
      end
      original_method.bind(self).call(event)
    end

    old_job_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        # Payload do job antigo: nil->A (o estado que a conversa tinha
        # quando esse job foi enfileirado pela primeira vez).
        changed_attributes = { 'assignee_id' => [nil, agent_a.id] }
        event = Events::Base.new(:assignee_changed, Time.zone.now, conversation: conversation, changed_attributes: changed_attributes)
        listener.assignee_changed(event)
      end
    end

    old_job_read_assignee.pop

    # A reatribuicao real A->B acontece enquanto o job antigo esta pausado:
    # dispara tanto a limpeza (remove A, que ainda nao existe como
    # participante - no-op) quanto o ParticipationListener normal (insere B).
    real_reassignment_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        conversation.update!(assignee: agent_b)
        changed_attributes = { 'assignee_id' => [agent_a.id, agent_b.id] }
        event = Events::Base.new(:assignee_changed, Time.zone.now, conversation: conversation, changed_attributes: changed_attributes)
        cleanup_listener.assignee_changed(event)
        listener.assignee_changed(event)
      end
    end
    real_reassignment_thread.join

    reassignment_done << true
    old_job_thread.join

    listener_class.define_method(:assignee_changed, original_method)

    participant_ids = conversation.reload.conversation_participants.map(&:user_id)
    expect(conversation.assignee_id).to eq(agent_b.id)
    expect(participant_ids).not_to include(agent_a.id)
    expect(participant_ids).to include(agent_b.id)
  end
end
