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
# Este spec forca a intercalacao exata do codigo real (nao mock RSpec -
# allow(...).to receive nao e garantidamente thread-safe nem reflete bem
# pausa-e-retoma) usando uma Fiber para o "job antigo", em vez de uma
# Thread.
#
# Por que Fiber e nao Thread com Queue (as duas abordagens foram testadas
# nesta rodada): o ponto exato da corrida fica DENTRO de
# conversation.with_lock (SELECT FOR UPDATE), entre a leitura do
# assignee_id e a insercao do participante. Pausar ali com uma Thread
# real == segurar um lock de linha Postgres aberto enquanto bloqueada em
# Queue#pop; qualquer outra conexao (inclusive a usada pela "reatribuicao
# real") que tente travar a MESMA linha fica esperando para sempre, porque
# quem teria que liberar e a propria thread pausada - deadlock
# auto-infligido pelo desenho do teste, nao o bug sendo reproduzido
# (confirmado nesta rodada em duas tentativas: RELEASE SAVEPOINT preso em
# "idle in transaction" por minutos, mesmo com DatabaseCleaner truncation
# e use_transactional_tests = false). Com Fiber, a pausa (Fiber.yield)
# acontece na MESMA thread/conexao/transacao: o "job antigo" e a
# "reatribuicao real" sao dois trechos de codigo intercalados de verdade
# (nao e mock - a Fiber literalmente para no meio da execucao real de
# assignee_changed e so retoma quando mandamos), mas sem jamais abrir uma
# segunda conexao Postgres concorrente disputando lock - o que e exatamente
# o cenario real: o "job antigo" e a "troca real" nunca rodam ao mesmo
# tempo de CPU de verdade (um processo so tem uma CPU rodando por vez por
# conexao), o que importa e a ORDEM em que cada passo acontece.
#
# CRITICO: a Fiber do job antigo opera sobre uma instancia Ruby PROPRIA do
# registro (Conversation.find por ID, como um job real faria ao
# desserializar via GlobalID) - nunca compartilhando o objeto `conversation`
# do exemplo, para a leitura dela (conversation.reload.assignee_id) nao
# ser afetada por mutacoes feitas no objeto da thread/fiber principal.
#
# Tem que FALHAR no codigo atual (sem lock/sem rede de seguranca) e PASSAR
# depois da correcao (conversation.with_lock + releitura final em
# Enterprise::ParticipationListener).
# rubocop:disable RSpec/DescribeClass -- cobre a interacao entre dois listeners
# (Enterprise::ParticipationListener e WhatsappParticipationCleanupListener)
# mais ActiveRecord::Relation (patch de teste), nao um unico metodo de uma
# classe so.
describe 'race with a concurrent reassignment (item 1)' do
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
    # Patch em ActiveRecord::Relation#find_or_create_by! (instancia, nao
    # metodo de classe) - conversation.conversation_participants e uma
    # CollectionProxy que delega find_or_create_by! pra Relation#find_or_create_by!,
    # NAO pro metodo de classe ConversationParticipant.find_or_create_by!
    # (confirmado nesta rodada via debug: patchear a classe nunca
    # interceptava a chamada feita atraves da associacao). Esse e o ponto
    # exato da corrida, chamado DEPOIS que o metodo real ja leu o
    # assignee_id atual e ANTES de persistir a linha. So pausa (Fiber.yield)
    # quando quem esta chamando e a fiber do job antigo.
    original_find_or_create_by = ActiveRecord::Relation.instance_method(:find_or_create_by!)
    old_job_fiber = nil

    ActiveRecord::Relation.define_method(:find_or_create_by!) do |*args, **kwargs|
      Fiber.yield(:about_to_insert) if klass == ConversationParticipant && Fiber.current == old_job_fiber
      original_find_or_create_by.bind_call(self, *args, **kwargs)
    end

    # CRITICO: instancia Ruby PROPRIA pro job antigo (ver comentario acima).
    old_job_conversation = Conversation.find(conversation.id)

    old_job_fiber = Fiber.new do
      # Payload do job antigo: nil->A (o estado que a conversa tinha quando
      # foi enfileirado pela primeira vez).
      changed_attributes = { 'assignee_id' => [nil, agent_a.id] }
      event = Events::Base.new(:assignee_changed, Time.zone.now, conversation: old_job_conversation, changed_attributes: changed_attributes)
      listener.assignee_changed(event)
      :finished
    end

    # Roda a fiber ate ela pausar dentro de find_or_create_by! (depois de
    # ja ter lido current_assignee_id = A via conversation.reload/with_lock
    # - leitura real, nao simulada).
    yielded_value = old_job_fiber.resume
    expect(yielded_value).to eq(:about_to_insert)

    # A reatribuicao real A->B acontece enquanto o job antigo esta pausado
    # (fiber suspensa, zero lock pendente nessa transacao - o with_lock do
    # job antigo, se aplicavel, ja foi encerrado no fim do bloco quando ele
    # retornou do yield? NAO: with_lock so fecha a transacao quando o BLOCO
    # termina, e a fiber esta pausada DENTRO do bloco - mas como e savepoint
    # da MESMA conexao/transacao raiz do exemplo, e nao uma segunda conexao,
    # nao ha espera de lock entre "processos" diferentes: e tudo a mesma
    # sessao Postgres, entao um savepoint aninhado aberto nao bloqueia o
    # proximo comando NESSA MESMA sessao - only bloquearia uma segunda
    # SESSAO tentando a mesma linha, que e justamente o que evitamos ao nao
    # usar uma segunda conexao real).
    conversation.update!(assignee: agent_b)
    changed_attributes = { 'assignee_id' => [agent_a.id, agent_b.id] }
    event = Events::Base.new(:assignee_changed, Time.zone.now, conversation: conversation, changed_attributes: changed_attributes)
    cleanup_listener.assignee_changed(event)
    listener.assignee_changed(event)

    # Retoma a fiber do job antigo: ela estava parada bem antes de inserir
    # o participante com o assignee_id que tinha lido (A, pego ANTES da
    # troca real acontecer) - completa find_or_create_by! e o restante do
    # metodo (rede de seguranca, se existir).
    result = old_job_fiber.resume
    expect(result).to eq(:finished)

    ActiveRecord::Relation.define_method(:find_or_create_by!, original_find_or_create_by)

    conversation.reload
    participant_ids = conversation.conversation_participants.map(&:user_id)
    expect(conversation.assignee_id).to eq(agent_b.id)
    expect(participant_ids).not_to include(agent_a.id)
    expect(participant_ids).to include(agent_b.id)
  end
end
# rubocop:enable RSpec/DescribeClass
