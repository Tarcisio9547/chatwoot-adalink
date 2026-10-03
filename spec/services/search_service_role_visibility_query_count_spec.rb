require 'rails_helper'

# A visibilidade por papel na busca não pode custar consulta extra quando não há
# o que restringir: administrador, agente sem custom_role e agente restrito numa
# conta sem caixa WhatsApp. A base de comparação é a mesma busca com o escopo de
# papel neutralizado (devolvendo a query intacta).
# rubocop:disable RSpec/DescribeMethod -- cobre o custo de consultas do escopo de papel
# em varios metodos da busca (conversas, mensagens e condicoes do Elasticsearch).
describe SearchService, 'role visibility query count' do
  let!(:account) { create(:account) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:plain_agent) { create(:user, account: account, role: :agent) }
  let!(:restricted_agent) { create(:user, account: account, role: :agent) }
  let!(:setor_role) { create(:custom_role, account: account, permissions: %w[conversation_participating_manage]) }

  before do
    [plain_agent, restricted_agent].each { |user| create(:inbox_member, user: user, inbox: inbox) }
    AccountUser.find_by(user: restricted_agent, account: account).update!(custom_role: setor_role)
    conversation = create(:conversation, account: account, inbox: inbox, assignee: restricted_agent)
    create(:message, account: account, inbox: inbox, conversation: conversation, content: 'zebraxpto')
    allow(account).to receive(:feature_enabled?).and_call_original
    allow(account).to receive(:feature_enabled?).with('search_with_gin').and_return(false)
    Current.account = account
  end

  after do
    Current.account = nil
    Current.account_user = nil
  end

  def build_service(user, search_type, neutralized:)
    # O controller ja carrega o AccountUser da requisicao em Current.account_user.
    Current.account_user = AccountUser.find_by(user: user, account: account)
    service = described_class.new(current_user: user, current_account: account, params: { q: 'zebraxpto' }, search_type: search_type)
    if neutralized
      service.define_singleton_method(:apply_role_visibility_to_messages) { |query| query }
      service.define_singleton_method(:apply_role_visibility_to_conversations) { |query| query }
    end
    service
  end

  def count_queries(&)
    count = 0
    counter = ->(_name, _started, _finished, _id, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA CACHE]) }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
    count
  end

  def queries_for(user, search_type, neutralized:)
    build_service(user, search_type, neutralized: neutralized).perform # aquece caches da classe
    service = build_service(user, search_type, neutralized: neutralized)
    count_queries { service.perform }
  end

  %w[Message Conversation].each do |search_type|
    describe "searching #{search_type}" do
      it 'adds no query for an administrator' do
        expect(queries_for(admin, search_type, neutralized: false)).to eq(queries_for(admin, search_type, neutralized: true))
      end

      it 'adds no query for an agent without a custom_role' do
        expect(queries_for(plain_agent, search_type, neutralized: false)).to eq(queries_for(plain_agent, search_type, neutralized: true))
      end

      it 'adds no query for a restricted agent in an account without a WhatsApp inbox' do
        expect(queries_for(restricted_agent, search_type, neutralized: false)).to eq(queries_for(restricted_agent, search_type, neutralized: true))
      end
    end
  end

  describe 'advanced search conditions (Elasticsearch)' do
    def where_conditions_queries(user, neutralized:)
      service = build_service(user, 'Message', neutralized: false)
      service.define_singleton_method(:apply_role_visibility_to_where_conditions) { |conditions| conditions } if neutralized
      service.send(:build_where_conditions)
      service = build_service(user, 'Message', neutralized: false)
      service.define_singleton_method(:apply_role_visibility_to_where_conditions) { |conditions| conditions } if neutralized
      count_queries { service.send(:build_where_conditions) }
    end

    it 'adds no query for admin, agent without role, or restricted agent in an account without WhatsApp' do
      [admin, plain_agent, restricted_agent].each do |user|
        expect(where_conditions_queries(user, neutralized: false)).to eq(where_conditions_queries(user, neutralized: true))
      end
    end
  end
end
# rubocop:enable RSpec/DescribeMethod
