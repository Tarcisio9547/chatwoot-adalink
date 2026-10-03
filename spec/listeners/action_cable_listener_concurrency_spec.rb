require 'rails_helper'

# ActionCableListener é Singleton, compartilhado por todas as threads do Puma e
# do Sidekiq. A conversa do evento atual não pode ficar em variável de instância:
# a thread 2 sobrescreveria o valor da thread 1 e o evento de uma conversa
# WhatsApp iria, sem filtro de papel, pra todos os membros da caixa.
#
# O spec força a intercalação com Queues dentro de around_member_filtering: as
# duas threads ficam DENTRO do bloco, cada uma com a sua marca já gravada. A
# thread 1 só roda o super (user_tokens) depois que a thread 2 entrou no bloco
# dela, e a thread 2 só sai depois que a thread 1 terminou. Com estado por
# thread (ActiveSupport::IsolatedExecutionState) a thread 1 mantém a conversa
# dela; com variável de instância leria a marca da thread 2, mesmo restaurando o
# valor anterior no ensure.
# rubocop:disable RSpec/DescribeMethod, RSpec/SpecFilePathFormat -- nao testa
# um metodo especifico, testa a ausencia de vazamento de estado entre
# threads compartilhando o Singleton (varios metodos privados envolvidos:
# around_member_filtering, user_tokens); nome do arquivo ja segue o padrao
# dos outros specs de ActionCableListener deste PR (role_visibility,
# upstream_coverage).
describe ActionCableListener, 'thread-safety of member filtering (concurrency)' do
  let(:listener) { described_class.instance }
  let(:barrier) { { wa_in: Queue.new, other_in: Queue.new, wa_done: Queue.new } }

  let!(:account) { create(:account) }
  let!(:setor_role) { create(:custom_role, account: account, permissions: %w[conversation_participating_manage]) }

  let!(:whatsapp_inbox) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox
  end
  let!(:wa_owner) { create(:user, account: account, role: :agent) }
  let!(:wa_setor_member) { create(:user, account: account, role: :agent) }
  let!(:wa_conversation) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: wa_owner) }

  let!(:other_inbox) { create(:inbox, account: account) }
  let!(:other_agent) { create(:user, account: account, role: :agent) }
  let!(:other_conversation) { create(:conversation, account: account, inbox: other_inbox, assignee: other_agent) }

  before do
    create(:inbox_member, user: wa_owner, inbox: whatsapp_inbox)
    create(:inbox_member, user: wa_setor_member, inbox: whatsapp_inbox)
    AccountUser.find_by(user: wa_setor_member, account: account).update(custom_role: setor_role)

    create(:inbox_member, user: other_agent, inbox: other_inbox)

    # HACK: to reload conversation inbox members (mesmo padrao ja usado nos
    # demais specs deste arquivo) - os membros sao adicionados acima, depois
    # da conversa (let!) ja ter carregado a associacao inbox.
    wa_conversation.inbox.reload
    other_conversation.inbox.reload
  end

  # Barreira direto no metodo privado (um mock RSpec nao e garantidamente
  # thread-safe). O original grava a marca e chama o bloco recebido, que aqui e
  # o lambda de cada thread.
  def barrier_wrapper_for(conversation, block)
    queues = barrier
    if conversation&.id == wa_conversation.id
      lambda do
        queues[:wa_in] << true
        queues[:other_in].pop
        block.call
        queues[:wa_done] << true
      end
    else
      lambda do
        queues[:other_in] << true
        queues[:wa_done].pop
        block.call
      end
    end
  end

  def run_in_thread(conversation)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        listener.conversation_updated(Events::Base.new(:'conversation.updated', Time.zone.now, conversation: conversation))
      end
    end
  end

  it 'does not leak the conversation context between threads sharing the same Singleton instance' do
    results = {}
    results_mutex = Mutex.new
    allow(ActionCableBroadcastJob).to receive(:perform_later) do |tokens, event_name, _payload|
      results_mutex.synchronize { results[Thread.current] = tokens } if event_name == 'conversation.updated'
    end

    spec = self
    listener_class = listener.singleton_class
    original_method = listener_class.instance_method(:around_member_filtering)
    listener_class.define_method(:around_member_filtering) do |conversation, &block|
      original_method.bind_call(self, conversation, &spec.barrier_wrapper_for(conversation, block))
    end

    begin
      thread1 = run_in_thread(wa_conversation)
      barrier[:wa_in].pop
      thread2 = run_in_thread(other_conversation)
      [thread1, thread2].each { |thread| thread.join(30) || raise('thread did not finish (deadlock?)') }
    ensure
      listener_class.define_method(:around_member_filtering, original_method)
    end

    thread1_tokens = results[thread1]
    thread2_tokens = results[thread2]

    # A conversa WhatsApp so pode ir pro dono (wa_owner). wa_setor_member tem
    # papel Setor (so ve o que e seu/participa) e NAO deveria receber. O bug
    # faz a thread 1 usar o estado que a thread 2 deixou (outra conversa,
    # sem regra de papel aplicavel a essa inbox) e mandar pra TODOS os
    # membros da inbox WhatsApp, incluindo wa_setor_member.
    expect(thread1_tokens).not_to be_nil
    expect(thread1_tokens).to include(wa_owner.pubsub_token)
    expect(thread1_tokens).not_to include(wa_setor_member.pubsub_token)

    # O evento da thread 2 (outro canal) precisa continuar identico ao
    # comportamento upstream: todos os membros da inbox, incluindo
    # other_agent.
    expect(thread2_tokens).not_to be_nil
    expect(thread2_tokens).to include(other_agent.pubsub_token)
  end
end
# rubocop:enable RSpec/DescribeMethod, RSpec/SpecFilePathFormat
