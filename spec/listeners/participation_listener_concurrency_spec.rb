require 'rails_helper'

# Corrida: o job assíncrono da troca nil->A lê o responsável (A) e é pausado
# antes de inserir o participante; nesse intervalo a conversa vai de A para B.
# Sem lock, a limpeza (que remove A) roda antes do job inserir A e A fica
# participante pra sempre. Com o lock de linha, a troca espera o job terminar.
#
# Duas threads, cada uma com sua conexão real do pool, e uma Queue como
# barreira. O grupo roda fora da transação de teste: dentro dela o Rails faz
# todas as threads compartilharem a mesma conexão (lock_thread), e dois
# clientes disputando a linha deixam de existir. Por isso os dados são
# commitados e removidos no `after`.
# rubocop:disable RSpec/DescribeClass -- cobre a interação entre dois listeners
# e o model, não uma classe só.
describe 'race between the participation listeners and a reassignment' do
  self.use_transactional_tests = false

  let(:participation_listener) { ParticipationListener.instance }
  let!(:account) { create(:account) }
  let!(:agent_a) { create(:user, account: account, role: :agent) }
  let!(:agent_b) { create(:user, account: account, role: :agent) }
  let!(:channel) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
  end
  let!(:conversation) { create(:conversation, account: account, inbox: channel.inbox, assignee: agent_a) }

  before do
    create(:inbox_member, user: agent_a, inbox: channel.inbox)
    create(:inbox_member, user: agent_b, inbox: channel.inbox)
  end

  after do
    ActiveRecord::Base.connection.tables.each do |table|
      next unless ActiveRecord::Base.connection.column_exists?(table, :account_id)

      ActiveRecord::Base.connection.delete("DELETE FROM #{table} WHERE account_id = #{account.id}")
    end
    InboxMember.where(inbox_id: channel.inbox.id).delete_all
    ContactInbox.where(inbox_id: channel.inbox.id).delete_all
    Inbox.where(id: channel.inbox.id).delete_all
    Channel::Whatsapp.where(id: channel.id).delete_all
    User.where(id: [agent_a.id, agent_b.id]).delete_all
    Account.where(id: account.id).delete_all
  end

  # Pausa a thread marcada como "job antigo" dentro de find_or_create_by! do
  # participante: depois da leitura do responsável e antes da escrita.
  def pause_old_job_when_inserting(paused:, resume:)
    original = ActiveRecord::Relation.instance_method(:find_or_create_by!)
    ActiveRecord::Relation.define_method(:find_or_create_by!) do |*args, **kwargs|
      if klass == ConversationParticipant && Thread.current[:old_job]
        paused << true
        resume.pop
      end
      original.bind_call(self, *args, **kwargs)
    end
    yield
  ensure
    ActiveRecord::Relation.define_method(:find_or_create_by!, original)
  end

  def run_in_thread(old_job: false, &)
    Thread.new do
      Thread.current[:old_job] = old_job
      ActiveRecord::Base.connection_pool.with_connection(&)
    end
  end

  def join_all(*threads)
    threads.each { |thread| thread.join(30) || raise('thread did not finish (deadlock?)') }
  end

  it 'does not leave the previous assignee as a participant when the job is paused during the reassignment' do
    paused = Queue.new
    resume = Queue.new

    pause_old_job_when_inserting(paused: paused, resume: resume) do
      old_job = run_in_thread(old_job: true) do
        event = Events::Base.new(:assignee_changed, Time.zone.now, conversation: Conversation.find(conversation.id))
        participation_listener.assignee_changed(event)
      end
      paused.pop(timeout: 15) || raise('old job never reached the insert')

      reassignment = run_in_thread do
        reassigned = Conversation.find(conversation.id)
        reassigned.update!(assignee: agent_b)
        participation_listener.assignee_changed(Events::Base.new(:assignee_changed, Time.zone.now, conversation: reassigned))
      end
      # Com o lock, a troca fica bloqueada esperando o job; sem ele, termina já.
      reassignment.join(2)

      resume << true
      join_all(old_job, reassignment)
    end

    participant_ids = ConversationParticipant.where(conversation_id: conversation.id).pluck(:user_id)
    expect(Conversation.find(conversation.id).assignee_id).to eq(agent_b.id)
    expect(participant_ids).to contain_exactly(agent_b.id)
  end
end
# rubocop:enable RSpec/DescribeClass
