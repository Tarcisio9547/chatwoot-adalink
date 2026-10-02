require 'rails_helper'

RSpec.describe Conversations::RoleVisibility do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:setor_role) { create(:custom_role, account: account, permissions: %w[conversation_participating_manage]) }
  let(:all_role) { create(:custom_role, account: account, permissions: %w[conversation_manage]) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:colleague) { create(:user, account: account, role: :agent) }
  let(:admin) { create(:user, account: account, role: :administrator) }

  before do
    create(:inbox_member, user: agent, inbox: inbox)
    create(:inbox_member, user: colleague, inbox: inbox)
  end

  # visible_to? não existe mais no código de produção (todo chamador trabalha em
  # lote via visible_members). A mesma regra é testada pela API real:
  # visible_members(conversation, [user]).include?(user).
  describe '.visible_members with a single-user list (replaces the removed .visible_to?)' do
    let!(:mine) { create(:conversation, account: account, inbox: inbox, assignee: agent) }
    let!(:colleague_conversation) { create(:conversation, account: account, inbox: inbox, assignee: colleague) }

    def visible?(user, conversation)
      described_class.visible_members(conversation, [user]).include?(user)
    end

    context 'with the Setor role (conversation_participating_manage only)' do
      before { AccountUser.find_by(user: agent, account: account).update(custom_role: setor_role) }

      it 'sees its own conversation' do
        expect(visible?(agent, mine)).to be true
      end

      it 'does not see a colleague conversation' do
        expect(visible?(agent, colleague_conversation)).to be false
      end

      it 'sees a conversation where it is an explicit participant' do
        create(:conversation_participant, conversation: colleague_conversation, account: account, user: agent)
        expect(visible?(agent, colleague_conversation)).to be true
      end
    end

    context 'with the "all conversations" role (conversation_manage)' do
      before { AccountUser.find_by(user: agent, account: account).update(custom_role: all_role) }

      it 'sees every conversation' do
        expect(visible?(agent, colleague_conversation)).to be true
      end
    end

    context 'when the user is an administrator' do
      it 'sees every conversation, custom role or not' do
        expect(visible?(admin, colleague_conversation)).to be true
      end
    end

    context 'when the agent has no custom role' do
      it 'sees every conversation (current behaviour, unchanged)' do
        expect(visible?(colleague, mine)).to be true
      end
    end

    context 'with a custom_role that has no conversation permission at all' do
      let(:empty_role) { create(:custom_role, account: account, permissions: %w[contact_manage]) }

      before { AccountUser.find_by(user: agent, account: account).update(custom_role: empty_role) }

      it 'does not see its own conversation (matches PermissionFilterService native behaviour, Conversation.none)' do
        expect(visible?(agent, mine)).to be false
      end

      it 'does not see a colleague conversation' do
        expect(visible?(agent, colleague_conversation)).to be false
      end
    end
  end

  describe '.unrestricted?' do
    it 'is true for an administrator' do
      expect(described_class.unrestricted?(admin, account.id)).to be true
    end

    it 'is true for an agent without a custom_role' do
      expect(described_class.unrestricted?(colleague, account.id)).to be true
    end

    it 'is false for an agent with a custom_role' do
      AccountUser.find_by(user: agent, account: account).update(custom_role: setor_role)
      expect(described_class.unrestricted?(agent, account.id)).to be false
    end

    # unrestricted? aceita account_user: opcional pra reaproveitar o AccountUser que o
    # chamador (SearchService) já tem em memória, sem um find_by a cada chamada.
    describe 'query reuse' do
      let!(:whatsapp_inbox) do
        create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox
      end

      before do
        create(:inbox_member, user: admin, inbox: whatsapp_inbox)
        create(:inbox_member, user: colleague, inbox: whatsapp_inbox)
        Current.account = account
      end

      after { Current.account = nil }

      it 'passing the preloaded account_user avoids an extra query, compared to not passing it' do
        account_user = AccountUser.find_by(user: admin, account: account)

        without_preload = count_queries { described_class.unrestricted?(admin, account.id) }
        with_preload = count_queries { described_class.unrestricted?(admin, account.id, account_user: account_user) }

        expect(with_preload).to eq(without_preload - 1)
      end

      it 'SearchService reuses its own memoized account_user - admin triggers zero extra queries' do
        search_service = SearchService.new(current_user: admin, current_account: account, params: { q: 'x' }, search_type: 'Message')
        preloaded_account_user = search_service.send(:account_user)

        query_count = count_queries { described_class.unrestricted?(admin, account.id, account_user: preloaded_account_user) }

        expect(query_count).to eq(0)
      end

      it 'agent without a custom_role also reuses the preloaded account_user with zero extra queries' do
        search_service = SearchService.new(current_user: colleague, current_account: account, params: { q: 'x' }, search_type: 'Message')
        preloaded_account_user = search_service.send(:account_user)

        query_count = count_queries { described_class.unrestricted?(colleague, account.id, account_user: preloaded_account_user) }

        expect(query_count).to eq(0)
      end

      def count_queries(&)
        count = 0
        counter_f = ->(_name, _started, _finished, _unique_id, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA CACHE]) }
        ActiveSupport::Notifications.subscribed(counter_f, 'sql.active_record', &)
        count
      end
    end
  end

  # unassigned_manage_only? (singular) não existe mais; o único chamador usa a
  # versão em lote unassigned_manage_only_members. Mesma regra, com lista de 1
  # elemento.
  describe '.unassigned_manage_only_members with a single-user list (replaces the removed .unassigned_manage_only?)' do
    let(:sem_atendente_role) { create(:custom_role, account: account, permissions: %w[conversation_unassigned_manage]) }

    it 'is true for a member whose only conversation permission is conversation_unassigned_manage' do
      AccountUser.find_by(user: agent, account: account).update(custom_role: sem_atendente_role)
      expect(described_class.unassigned_manage_only_members([agent], account.id)).to include(agent)
    end

    it 'is false for a member with conversation_manage' do
      AccountUser.find_by(user: agent, account: account).update(custom_role: all_role)
      expect(described_class.unassigned_manage_only_members([agent], account.id)).not_to include(agent)
    end

    it 'is false for an administrator' do
      expect(described_class.unassigned_manage_only_members([admin], account.id)).not_to include(admin)
    end
  end

  describe '.filter' do
    let!(:mine) { create(:conversation, account: account, inbox: inbox, assignee: agent) }
    let!(:colleague_conversation) { create(:conversation, account: account, inbox: inbox, assignee: colleague) }
    let!(:unassigned_conversation) { create(:conversation, account: account, inbox: inbox, assignee: nil) }

    context 'with the Setor role' do
      before { AccountUser.find_by(user: agent, account: account).update(custom_role: setor_role) }

      it 'only returns the conversations assigned to the agent or where they participate' do
        result = described_class.filter(account.conversations, agent, account)

        expect(result).to include(mine)
        expect(result).not_to include(colleague_conversation)
        expect(result).not_to include(unassigned_conversation)
      end
    end

    context 'when the user is an administrator' do
      it 'returns every conversation' do
        result = described_class.filter(account.conversations, admin, account)

        expect(result).to include(mine, colleague_conversation, unassigned_conversation)
      end
    end

    context 'with a custom_role that has no conversation permission at all' do
      let(:empty_role) { create(:custom_role, account: account, permissions: %w[contact_manage]) }

      before { AccountUser.find_by(user: agent, account: account).update(custom_role: empty_role) }

      it 'returns no conversations (matches PermissionFilterService native behaviour)' do
        result = described_class.filter(account.conversations, agent, account)

        expect(result).to be_empty
      end
    end
  end

  describe '.visible_members (query count)' do
    let!(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: agent) }

    before { AccountUser.find_by(user: agent, account: account).update(custom_role: setor_role) }

    it 'runs a constant number of queries regardless of how many members are passed' do
      few_members = inbox.members.to_a
      query_count_few = count_queries { described_class.visible_members(conversation, few_members) }

      more_members = Array.new(5) do
        member = create(:user, account: account, role: :agent)
        create(:inbox_member, user: member, inbox: inbox)
        member
      end
      many_members = few_members + more_members

      query_count_many = count_queries { described_class.visible_members(conversation, many_members) }

      expect(query_count_many).to eq(query_count_few)
    end

    def count_queries(&)
      count = 0
      counter_f = ->(_name, _started, _finished, _unique_id, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA CACHE]) }
      ActiveSupport::Notifications.subscribed(counter_f, 'sql.active_record', &)
      count
    end
  end
end
