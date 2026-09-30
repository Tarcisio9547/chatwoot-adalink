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

  describe '.visible_to?' do
    let!(:mine) { create(:conversation, account: account, inbox: inbox, assignee: agent) }
    let!(:colleague_conversation) { create(:conversation, account: account, inbox: inbox, assignee: colleague) }

    context 'with the Setor role (conversation_participating_manage only)' do
      before { AccountUser.find_by(user: agent, account: account).update(custom_role: setor_role) }

      it 'sees its own conversation' do
        expect(described_class.visible_to?(agent, mine)).to be true
      end

      it 'does not see a colleague conversation' do
        expect(described_class.visible_to?(agent, colleague_conversation)).to be false
      end

      it 'sees a conversation where it is an explicit participant' do
        create(:conversation_participant, conversation: colleague_conversation, account: account, user: agent)
        expect(described_class.visible_to?(agent, colleague_conversation)).to be true
      end
    end

    context 'with the "all conversations" role (conversation_manage)' do
      before { AccountUser.find_by(user: agent, account: account).update(custom_role: all_role) }

      it 'sees every conversation' do
        expect(described_class.visible_to?(agent, colleague_conversation)).to be true
      end
    end

    context 'when the user is an administrator' do
      it 'sees every conversation, custom role or not' do
        expect(described_class.visible_to?(admin, colleague_conversation)).to be true
      end
    end

    context 'when the agent has no custom role' do
      it 'sees every conversation (current behaviour, unchanged)' do
        expect(described_class.visible_to?(colleague, mine)).to be true
      end
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
  end
end
