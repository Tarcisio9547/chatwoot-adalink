require 'rails_helper'

# Adalink: #2083 - fora de caixas Channel::Whatsapp, a busca continua
# identica ao comportamento de hoje, mesmo para um usuario com papel
# restrito. Arquivo separado para nao estourar RSpec/MultipleMemoizedHelpers
# em search_service_role_visibility_spec.rb.
describe SearchService do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account: account) }
  let!(:colleague) { create(:user, account: account, role: :agent) }
  let!(:setor_role) { create(:custom_role, account: account, permissions: %w[conversation_participating_manage]) }
  let!(:other_inbox) { create(:inbox, account: account) }
  let!(:other_colleague_conversation) { create(:conversation, account: account, inbox: other_inbox, assignee: colleague) }
  let!(:other_colleague_message) do
    create(:message, account: account, inbox: other_inbox, conversation: other_colleague_conversation, content: 'zebraxpto de outra caixa')
  end

  before do
    create(:inbox_member, user: user, inbox: other_inbox)
    create(:inbox_member, user: colleague, inbox: other_inbox)
    AccountUser.find_by(user: user, account: account).update(custom_role: setor_role)
    Current.account = account
  end

  after do
    Current.account = nil
  end

  describe 'role-based visibility (#2083) - inbox is not Channel::Whatsapp' do
    it 'search stays identical to the current behaviour (no role filtering)' do
      params = { q: 'zebraxpto' }
      search_service = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Message')

      results = search_service.perform[:messages]
      expect(results).to include(other_colleague_message)
    end
  end
end
