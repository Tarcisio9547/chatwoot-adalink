require 'rails_helper'

RSpec.describe Enterprise::Conversations::PermissionFilterService do
  let(:account) { create(:account) }
  # Create conversations with different states
  let!(:assigned_conversation) { create(:conversation, account: account, inbox: inbox, assignee: agent) }
  let!(:unassigned_conversation) { create(:conversation, account: account, inbox: inbox, assignee: nil) }
  let!(:another_assigned_conversation) { create(:conversation, account: account, inbox: inbox, assignee: create(:user, account: account)) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:inbox2) { create(:inbox, account: account) }
  let!(:another_inbox_conversation) { create(:conversation, account: account, inbox: inbox2) }

  # This inbox_member is used to establish the agent's access to the inbox
  before { create(:inbox_member, user: agent, inbox: inbox) }

  describe '#perform' do
    context 'when user is an administrator' do
      it 'returns all conversations' do
        result = Conversations::PermissionFilterService.new(
          account.conversations,
          admin,
          account
        ).perform

        expect(result).to include(assigned_conversation)
        expect(result).to include(unassigned_conversation)
        expect(result).to include(another_assigned_conversation)
        expect(result.count).to eq(4)
      end
    end

    context 'when user is a regular agent' do
      it 'returns all conversations in assigned inboxes' do
        result = Conversations::PermissionFilterService.new(
          account.conversations,
          agent,
          account
        ).perform

        expect(result).to include(assigned_conversation)
        expect(result).to include(unassigned_conversation)
        expect(result).to include(another_assigned_conversation)
        expect(result).not_to include(another_inbox_conversation)
        expect(result.count).to eq(3)
      end
    end

    context 'when user has conversation_manage permission' do
      # Test with a new clean state for each test case
      it 'returns all conversations' do
        # Create a new isolated test environment
        test_account = create(:account)
        test_inbox = create(:inbox, account: test_account)
        test_inbox2 = create(:inbox, account: test_account)
        # Create test agent
        test_agent = create(:user, account: test_account, role: :agent)
        create(:inbox_member, user: test_agent, inbox: test_inbox)

        # Create custom role with conversation_manage permission
        test_custom_role = create(:custom_role, account: test_account, permissions: ['conversation_manage'])
        account_user = AccountUser.find_by(user: test_agent, account: test_account)
        account_user.update(role: :agent, custom_role: test_custom_role)

        # Create some conversations
        assigned_conversation = create(:conversation, account: test_account, inbox: test_inbox, assignee: test_agent)
        unassigned_conversation = create(:conversation, account: test_account, inbox: test_inbox, assignee: nil)
        other_assigned_conversation = create(:conversation, account: test_account, inbox: test_inbox, assignee: create(:user, account: test_account))
        other_inbox_conversation = create(:conversation, account: test_account, inbox: test_inbox2, assignee: nil)

        # Run the test
        result = Conversations::PermissionFilterService.new(
          test_account.conversations,
          test_agent,
          test_account
        ).perform

        # Should have access to all conversations
        expect(result.count).to eq(3)
        expect(result).to include(assigned_conversation)
        expect(result).to include(unassigned_conversation)
        expect(result).to include(other_assigned_conversation)
        expect(result).not_to include(other_inbox_conversation)
      end
    end

    context 'when user has conversation_participating_manage permission' do
      it 'returns only conversations assigned to the agent' do
        # Create a new isolated test environment
        test_account = create(:account)
        test_inbox = create(:inbox, account: test_account)
        test_inbox2 = create(:inbox, account: test_account)

        # Create test agent
        test_agent = create(:user, account: test_account, role: :agent)
        create(:inbox_member, user: test_agent, inbox: test_inbox)

        # Create a custom role with only the conversation_participating_manage permission
        test_custom_role = create(:custom_role, account: test_account, permissions: %w[conversation_participating_manage])

        account_user = AccountUser.find_by(user: test_agent, account: test_account)
        account_user.update(role: :agent, custom_role: test_custom_role)

        # Create some conversations
        other_conversation = create(:conversation, account: test_account, inbox: test_inbox)
        assigned_conversation = create(:conversation, account: test_account, inbox: test_inbox, assignee: test_agent)
        other_inbox_conversation = create(:conversation, account: test_account, inbox: test_inbox2, assignee: nil)

        # Run the test
        result = Conversations::PermissionFilterService.new(
          test_account.conversations,
          test_agent,
          test_account
        ).perform

        # Should only see conversations assigned to this agent
        expect(result.count).to eq(1)
        expect(result.first.assignee).to eq(test_agent)
        expect(result).to include(assigned_conversation)
        expect(result).not_to include(other_conversation)
        expect(result).not_to include(other_inbox_conversation)
      end
    end

    context 'when user has conversation_unassigned_manage permission' do
      it 'returns unassigned conversations AND mine' do
        # Create a new isolated test environment
        test_account = create(:account)
        test_inbox = create(:inbox, account: test_account)
        test_inbox2 = create(:inbox, account: test_account)

        # Create test agent
        test_agent = create(:user, account: test_account, role: :agent)
        create(:inbox_member, user: test_agent, inbox: test_inbox)

        # Create a custom role with only the conversation_unassigned_manage permission
        test_custom_role = create(:custom_role, account: test_account, permissions: %w[conversation_unassigned_manage])

        account_user = AccountUser.find_by(user: test_agent, account: test_account)
        account_user.update(role: :agent, custom_role: test_custom_role)

        # Create some conversations
        assigned_conversation = create(:conversation, account: test_account, inbox: test_inbox, assignee: test_agent)
        unassigned_conversation = create(:conversation, account: test_account, inbox: test_inbox, assignee: nil)
        other_assigned_conversation = create(:conversation, account: test_account, inbox: test_inbox, assignee: create(:user, account: test_account))
        other_inbox_conversation = create(:conversation, account: test_account, inbox: test_inbox2, assignee: nil)

        # Run the test
        result = Conversations::PermissionFilterService.new(
          test_account.conversations,
          test_agent,
          test_account
        ).perform

        # Should see unassigned conversations AND conversations assigned to this agent
        expect(result.count).to eq(2)
        expect(result).to include(unassigned_conversation)
        expect(result).to include(assigned_conversation)

        # Should NOT include conversations assigned to others
        expect(result).not_to include(other_assigned_conversation)
        expect(result).not_to include(other_inbox_conversation)
      end
    end

    context 'when the user is an explicit participant of a conversation assigned to someone else' do
      let(:test_account) { create(:account) }
      let(:test_inbox) { create(:inbox, account: test_account) }
      let(:test_agent) { create(:user, account: test_account, role: :agent) }
      let(:colleague) { create(:user, account: test_account, role: :agent) }
      let!(:colleague_conversation) { create(:conversation, account: test_account, inbox: test_inbox, assignee: colleague) }
      let!(:unrelated_colleague_conversation) { create(:conversation, account: test_account, inbox: test_inbox, assignee: colleague) }
      let!(:unassigned_conversation) { create(:conversation, account: test_account, inbox: test_inbox, assignee: nil) }
      let!(:mine) { create(:conversation, account: test_account, inbox: test_inbox, assignee: test_agent) }

      before do
        create(:inbox_member, user: test_agent, inbox: test_inbox)
        create(:conversation_participant, conversation: colleague_conversation, account: test_account, user: test_agent)
      end

      def result_for(permissions)
        role = create(:custom_role, account: test_account, permissions: permissions)
        AccountUser.find_by(user: test_agent, account: test_account).update!(role: :agent, custom_role: role)
        Conversations::PermissionFilterService.new(test_account.conversations, test_agent, test_account).perform
      end

      it 'lists it for "Minhas" (conversation_participating_manage) next to the ones assigned to the user' do
        result = result_for(%w[conversation_participating_manage])

        expect(result).to contain_exactly(mine, colleague_conversation)
      end

      it 'lists it for "Nao atribuidas" (conversation_unassigned_manage) next to unassigned and mine' do
        result = result_for(%w[conversation_unassigned_manage])

        expect(result).to contain_exactly(mine, unassigned_conversation, colleague_conversation)
      end

      it 'keeps hiding the conversations of colleagues where the user is not a participant' do
        expect(result_for(%w[conversation_participating_manage])).not_to include(unrelated_colleague_conversation)
        expect(result_for(%w[conversation_unassigned_manage])).not_to include(unrelated_colleague_conversation)
      end

      it 'lists the conversation for a participant who is not a member of the inbox' do
        outsider = create(:user, account: test_account, role: :agent)
        create(:conversation_participant, conversation: colleague_conversation, account: test_account, user: outsider)
        role = create(:custom_role, account: test_account, permissions: %w[conversation_participating_manage])
        AccountUser.find_by(user: outsider, account: test_account).update!(role: :agent, custom_role: role)

        result = Conversations::PermissionFilterService.new(test_account.conversations, outsider, test_account).perform

        expect(result).to contain_exactly(colleague_conversation)
      end

      it 'does not widen anything for conversation_manage (already sees every conversation of its inboxes)' do
        result = result_for(%w[conversation_manage])

        expect(result).to contain_exactly(mine, unassigned_conversation, colleague_conversation, unrelated_colleague_conversation)
      end
    end

    context 'when user has both participating and unassigned permissions (hierarchical test)' do
      it 'gives higher priority to unassigned_manage over participating_manage' do
        # Create a new isolated test environment
        test_account = create(:account)
        test_inbox = create(:inbox, account: test_account)
        test_inbox2 = create(:inbox, account: test_account)

        # Create test agent
        test_agent = create(:user, account: test_account, role: :agent)
        create(:inbox_member, user: test_agent, inbox: test_inbox)

        # Create a custom role with both participating and unassigned permissions
        permissions = %w[conversation_participating_manage conversation_unassigned_manage]
        test_custom_role = create(:custom_role, account: test_account, permissions: permissions)

        account_user = AccountUser.find_by(user: test_agent, account: test_account)
        account_user.update(role: :agent, custom_role: test_custom_role)

        # Create some conversations
        assigned_to_agent = create(:conversation, account: test_account, inbox: test_inbox, assignee: test_agent)
        unassigned_conversation = create(:conversation, account: test_account, inbox: test_inbox, assignee: nil)
        other_assigned_conversation = create(:conversation, account: test_account, inbox: test_inbox, assignee: create(:user, account: test_account))
        other_inbox_conversation = create(:conversation, account: test_account, inbox: test_inbox2, assignee: nil)

        # Run the test
        result = Conversations::PermissionFilterService.new(
          test_account.conversations,
          test_agent,
          test_account
        ).perform

        # Should behave the same as conversation_unassigned_manage test
        # - Show both unassigned and assigned to this agent
        # - Do not show conversations assigned to others
        expect(result.count).to eq(2)
        expect(result).to include(unassigned_conversation)
        expect(result).to include(assigned_to_agent)
        expect(result).not_to include(other_assigned_conversation)
        expect(result).not_to include(other_inbox_conversation)
      end
    end
  end
end
