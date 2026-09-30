require 'rails_helper'

# Adalink: #2083 - na caixa WhatsApp Cloud, a busca (conversas e mensagens)
# respeita o papel do usuario. Outras caixas e usuarios sem papel restrito
# continuam identicos ao comportamento anterior. Arquivo separado de
# search_service_spec.rb para nao herdar os memoized helpers do describe
# principal (harry, message, portal, article), que nao sao usados aqui.
describe SearchService do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account: account) }
  let!(:colleague) { create(:user, account: account, role: :agent) }
  let!(:whatsapp_inbox) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox
  end
  let!(:setor_role) { create(:custom_role, account: account, permissions: %w[conversation_participating_manage]) }
  let!(:mine_conversation) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: user) }
  let!(:colleague_conversation) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: colleague) }
  let!(:mine_message) { create(:message, account: account, inbox: whatsapp_inbox, conversation: mine_conversation, content: 'senha do zebraxpto') }
  let!(:colleague_message) do
    create(:message, account: account, inbox: whatsapp_inbox, conversation: colleague_conversation, content: 'senha do zebraxpto')
  end

  before do
    create(:inbox_member, user: user, inbox: whatsapp_inbox)
    create(:inbox_member, user: colleague, inbox: whatsapp_inbox)
    Current.account = account
  end

  after do
    Current.account = nil
  end

  describe 'role-based visibility on Channel::Whatsapp inboxes (#2083)' do
    context 'when the agent has the Setor role (conversation_participating_manage only)' do
      before { AccountUser.find_by(user: user, account: account).update(custom_role: setor_role) }

      it 'does not find a colleague conversation by message content' do
        params = { q: 'zebraxpto' }
        search_service = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Message')

        results = search_service.perform[:messages]
        expect(results).to include(mine_message)
        expect(results).not_to include(colleague_message)
      end

      it 'does not find a colleague conversation in the conversation search' do
        params = { q: colleague_conversation.display_id.to_s }
        search_service = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Conversation')

        results = search_service.perform[:conversations]
        expect(results).not_to include(colleague_conversation)
      end

      it 'finds its own conversation' do
        params = { q: mine_conversation.display_id.to_s }
        search_service = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Conversation')

        results = search_service.perform[:conversations]
        expect(results).to include(mine_conversation)
      end
    end

    context 'when the user is an administrator' do
      let!(:admin) { create(:user, account: account, role: :administrator) }

      it 'finds messages from every conversation in the WhatsApp inbox' do
        params = { q: 'zebraxpto' }
        search_service = described_class.new(current_user: admin, current_account: account, params: params, search_type: 'Message')

        results = search_service.perform[:messages]
        expect(results).to include(mine_message, colleague_message)
      end
    end

    context 'when the agent has no custom role' do
      it 'keeps the current behaviour (finds every message in its accessible inboxes)' do
        params = { q: 'zebraxpto' }
        search_service = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Message')

        results = search_service.perform[:messages]
        expect(results).to include(mine_message, colleague_message)
      end
    end

    context 'when the inbox is not Channel::Whatsapp' do
      let!(:other_inbox) { create(:inbox, account: account) }
      let!(:other_colleague_conversation) { create(:conversation, account: account, inbox: other_inbox, assignee: colleague) }
      let!(:other_colleague_message) do
        create(:message, account: account, inbox: other_inbox, conversation: other_colleague_conversation, content: 'zebraxpto de outra caixa')
      end

      before do
        create(:inbox_member, user: user, inbox: other_inbox)
        create(:inbox_member, user: colleague, inbox: other_inbox)
        AccountUser.find_by(user: user, account: account).update(custom_role: setor_role)
      end

      it 'search stays identical to the current behaviour (no role filtering)' do
        params = { q: 'zebraxpto' }
        search_service = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Message')

        results = search_service.perform[:messages]
        expect(results).to include(other_colleague_message)
      end
    end
  end
end
