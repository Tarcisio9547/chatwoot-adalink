require 'rails_helper'

RSpec.describe Agents::DestroyJob do
  subject(:job) { described_class.perform_later(account, user) }

  let!(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:team1) { create(:team, account: account) }
  let!(:inbox) { create(:inbox, account: account) }

  before do
    create(:team_member, team: team1, user: user)
    create(:inbox_member, inbox: inbox, user: user)
    create(:conversation, account: account, assignee: user, inbox: inbox)
  end

  it 'enqueues the job' do
    expect { job }.to have_enqueued_job(described_class)
      .with(account, user)
      .on_queue('low')
  end

  describe '#perform' do
    it 'removes the participations of the agent in that account (they would still give access to conversations)' do
      other_account = create(:account)
      create(:account_user, account: other_account, user: user, role: :agent)
      other_conversation = create(:conversation, account: other_account)
      mine = create(:conversation, account: account, inbox: inbox)
      other_participant = create(:user, account: account)
      create(:conversation_participant, conversation: mine, account: account, user: user)
      create(:conversation_participant, conversation: mine, account: account, user: other_participant)
      create(:conversation_participant, conversation: other_conversation, account: other_account, user: user)

      described_class.perform_now(account, user)

      expect(ConversationParticipant.where(account_id: account.id, user_id: user.id)).to be_empty
      expect(ConversationParticipant.where(conversation_id: mine.id).pluck(:user_id)).to eq([other_participant.id])
      expect(ConversationParticipant.where(account_id: other_account.id, user_id: user.id).count).to eq(1)
    end

    it 'remove inboxes, teams, and conversations when removed from account' do
      described_class.perform_now(account, user)

      user.reload
      expect(user.teams.length).to eq 0
      expect(user.inboxes.length).to eq 0
      expect(user.notification_settings.length).to eq 0
      expect(user.assigned_conversations.where(account: account).length).to eq 0
    end
  end
end
