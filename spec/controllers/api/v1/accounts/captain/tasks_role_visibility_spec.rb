require 'rails_helper'

# As tarefas do Captain (resumo, sugestão de resposta e de etiqueta) leem a
# conversa por conversation_display_id e mandam o texto dela pro LLM. Numa caixa
# WhatsApp, quem não enxerga a conversa pelo papel (ex.: Setor pedindo a conversa
# de um colega) não pode obter o resumo dela. Outras caixas seguem como antes.
# O LLM é falso e registra tudo o que receberia.
describe 'Captain tasks role visibility', type: :request do
  let!(:account) { create(:account) }
  let!(:agent) { create(:user, account: account, role: :agent) }
  let!(:colleague) { create(:user, account: account, role: :agent) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:setor_role) { create(:custom_role, account: account, permissions: %w[conversation_participating_manage]) }
  let!(:whatsapp_inbox) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox
  end
  let(:secret) { 'segredo do cliente do colega' }
  let(:llm_inputs) { [] }
  let(:mock_chat) { instance_double(RubyLLM::Chat).as_null_object }
  let(:mock_context) { instance_double(RubyLLM::Context, chat: mock_chat) }
  let(:mock_response) { instance_double(RubyLLM::Message, content: 'resposta do llm', input_tokens: 10, output_tokens: 5) }

  before do
    create(:installation_config, name: 'CAPTAIN_OPEN_AI_API_KEY', value: 'test-key')
    create(:label, account: account, title: 'vendas')
    [agent, colleague].each { |user| create(:inbox_member, user: user, inbox: whatsapp_inbox) }
    AccountUser.find_by(user: agent, account: account).update!(custom_role: setor_role)

    allow(Llm::Config).to receive(:with_api_key).and_yield(mock_context)
    allow(mock_chat).to receive(:ask) do |*args|
      llm_inputs << args.inspect
      mock_response
    end
    allow_any_instance_of(Account).to receive(:feature_enabled?).and_call_original # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(Account).to receive(:feature_enabled?).with('captain_tasks').and_return(true) # rubocop:disable RSpec/AnyInstance
  end

  def task_path(action)
    "/api/v1/accounts/#{account.id}/captain/tasks/#{action}"
  end

  def call_task(action, user, conversation)
    post task_path(action), params: { conversation_display_id: conversation.display_id }, headers: user.create_new_auth_token, as: :json
  end

  # label_suggestion exige pelo menos 3 mensagens recebidas
  def add_customer_messages(conversation, text)
    3.times { create(:message, account: account, inbox: conversation.inbox, conversation: conversation, message_type: :incoming, content: text) }
  end

  def colleague_conversation
    @colleague_conversation ||= create(:conversation, account: account, inbox: whatsapp_inbox, assignee: colleague).tap do |conversation|
      add_customer_messages(conversation, secret)
    end
  end

  %w[summarize reply_suggestion label_suggestion].each do |action|
    describe "POST #{action}" do
      it 'does not run the task nor call the LLM for a colleague conversation (Setor role)' do
        call_task(action, agent, colleague_conversation)

        expect(response).to have_http_status(:not_found)
        expect(llm_inputs).to be_empty
        expect(response.body).not_to include(secret)
      end

      it 'runs the task for the assignee' do
        own = create(:conversation, account: account, inbox: whatsapp_inbox, assignee: agent)
        add_customer_messages(own, 'minha conversa')

        call_task(action, agent, own)

        expect(response).not_to have_http_status(:not_found)
        expect(llm_inputs.join).to include('minha conversa')
      end

      it 'runs the task for an administrator on any WhatsApp conversation' do
        call_task(action, admin, colleague_conversation)

        expect(response).not_to have_http_status(:not_found)
        expect(llm_inputs.join).to include(secret)
      end

      it 'keeps working on other channels, whatever the role (current behaviour, unchanged)' do
        other_inbox = create(:inbox, account: account)
        create(:inbox_member, user: agent, inbox: other_inbox)
        other = create(:conversation, account: account, inbox: other_inbox, assignee: colleague)
        add_customer_messages(other, 'outra caixa')

        call_task(action, agent, other)

        expect(response).not_to have_http_status(:not_found)
        expect(llm_inputs.join).to include('outra caixa')
      end
    end
  end

  it 'does not interfere with tasks that carry no conversation' do
    post task_path('rewrite'), params: { content: 'texto', operation: 'fix_spelling_grammar' }, headers: agent.create_new_auth_token, as: :json

    expect(response).not_to have_http_status(:not_found)
  end
end
