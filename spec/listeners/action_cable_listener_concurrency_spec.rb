require 'rails_helper'

# ActionCableListener é Singleton, compartilhado por todas as threads do Puma e
# do Sidekiq. A conversa do evento atual não pode ficar em variável de instância:
# a thread 2 sobrescreveria o valor da thread 1 e o evento de uma conversa
# WhatsApp iria, sem filtro de papel, pra todos os membros da caixa.
#
# O spec força a intercalação com uma Queue como barreira dentro de
# around_member_filtering: a thread 1 pausa depois de marcar a conversa, a
# thread 2 processa um evento de outra caixa até o fim, e só então a thread 1
# continua. Com estado por thread (ActiveSupport::IsolatedExecutionState) ela
# mantém a conversa dela; com variável de instância leria a da thread 2.
# rubocop:disable RSpec/DescribeMethod, RSpec/SpecFilePathFormat -- nao testa
# um metodo especifico, testa a ausencia de vazamento de estado entre
# threads compartilhando o Singleton (varios metodos privados envolvidos:
# around_member_filtering, user_tokens); nome do arquivo ja segue o padrao
# dos outros specs de ActionCableListener deste PR (role_visibility,
# upstream_coverage).
describe ActionCableListener, 'thread-safety of member filtering (concurrency)' do
  let(:listener) { described_class.instance }

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

  it 'does not leak the conversation context between threads sharing the same Singleton instance' do
    thread1_entered_yield = Queue.new
    thread2_finished = Queue.new
    results = {}
    results_mutex = Mutex.new

    allow(ActionCableBroadcastJob).to receive(:perform_later) do |tokens, event_name, _payload|
      next unless event_name == 'conversation.updated'

      results_mutex.synchronize { results[Thread.current] = tokens }
    end

    # Insere a barreira DIRETO no metodo privado around_member_filtering (em
    # vez de um mock RSpec, que nao e garantidamente thread-safe): guarda a
    # implementacao original e a substitui por uma versao que, so na
    # chamada com a conversa WhatsApp, pausa exatamente entre marcar o
    # estado e rodar o bloco (que aciona user_tokens) - a janela onde o bug
    # de concorrencia vive. Restaurado no ensure do teste.
    listener_class = listener.singleton_class
    original_method = listener_class.instance_method(:around_member_filtering)
    wa_conversation_id = wa_conversation.id

    listener_class.define_method(:around_member_filtering) do |conversation, &block|
      if conversation&.id == wa_conversation_id
        wrapped = lambda do
          thread1_entered_yield << true
          thread2_finished.pop
          block.call
        end
        original_method.bind_call(self, conversation, &wrapped)
      else
        original_method.bind_call(self, conversation, &block)
      end
    end

    thread1 = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        event = Events::Base.new(:'conversation.updated', Time.zone.now, conversation: wa_conversation)
        listener.conversation_updated(event)
      end
    end

    thread1_entered_yield.pop

    thread2 = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        event = Events::Base.new(:'conversation.updated', Time.zone.now, conversation: other_conversation)
        listener.conversation_updated(event)
      end
    end
    thread2.join
    thread2_finished << true

    thread1.join

    listener_class.define_method(:around_member_filtering, original_method)

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
