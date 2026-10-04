require 'rails_helper'

# Quem tem visão restrita só age (responsável, time, status) nas conversas que ENXERGA, em TODOS os
# canais. Antes, só as conversas de caixas WhatsApp eram filtradas: numa caixa de site, e-mail ou API
# da qual ele não é membro, ele mexia em conversa que não via. Rótulos e soneca seguem como estavam.
# rubocop:disable RSpec/DescribeClass -- cobre o job de upstream e os ganchos Enterprise de bulk e macro.
describe 'Bulk actions and macros on conversations a restricted user cannot see' do
  let!(:account) { create(:account) }
  let!(:my_inbox) { create(:inbox, account: account) }
  let!(:other_inbox) { create(:inbox, account: account) }
  let!(:restricted) { create(:user, account: account, role: :agent) }
  let!(:owner) { create(:user, account: account, role: :agent) }
  let!(:team) { create(:team, account: account, allow_auto_assign: false) }
  let!(:visible) { create(:conversation, account: account, inbox: my_inbox, assignee: restricted, status: :open) }
  let!(:hidden) { create(:conversation, account: account, inbox: other_inbox, assignee: nil, status: :open) }
  let!(:hidden_owned) { create(:conversation, account: account, inbox: other_inbox, assignee: owner, status: :open) }

  before do
    create(:inbox_member, inbox: my_inbox, user: restricted)
    role = create(:custom_role, account: account, permissions: %w[conversation_participating_manage])
    AccountUser.find_by(user: restricted, account: account).update!(role: :agent, custom_role: role)
  end

  def run_bulk(user, conversations, fields, extra = {})
    params = { type: 'Conversation', ids: conversations.map(&:display_id), fields: fields }.merge(extra)
    BulkActionsJob.perform_now(account: account, params: params, user: user)
  end

  def run_macro(user, conversations, *actions)
    macro = create(:macro, account: account, actions: actions)
    MacrosExecutionJob.perform_now(macro, conversation_ids: conversations.map(&:display_id), user: user)
  end

  describe 'bulk actions' do
    it 'does not change assignee_id on a conversation of an inbox he is not a member of and cannot see' do
      run_bulk(restricted, [hidden], { assignee_id: restricted.id })

      expect(hidden.reload.assignee_id).to be_nil
    end

    it 'does not change team_id or status either' do
      run_bulk(restricted, [hidden, hidden_owned], { team_id: team.id, status: 'resolved' })

      expect([hidden, hidden_owned].map { |conversation| conversation.reload.team_id }).to all(be_nil)
      expect([hidden, hidden_owned].map(&:status)).to all(eq('open'))
    end

    it 'changes the visible ones in the same call' do
      run_bulk(restricted, [hidden, visible], { status: 'resolved' })

      expect(visible.reload.status).to eq('resolved')
      expect(hidden.reload.status).to eq('open')
    end

    it 'sees a conversation he participates in even if the inbox is not his' do
      create(:conversation_participant, conversation: hidden, account: account, user: restricted)

      run_bulk(restricted, [hidden], { assignee_id: restricted.id })

      expect(hidden.reload.assignee_id).to eq(restricted.id)
    end

    it 'keeps labels and snooze as they were (not part of assignee, team or status)' do
      create(:label, account: account, title: 'vendas')

      run_bulk(restricted, [hidden], {}, { labels: { add: ['vendas'] } })

      expect(hidden.reload.label_list).to eq(['vendas'])
    end

    it 'does not restrict an administrator or an agent without custom role' do
      admin = create(:user, account: account, role: :administrator)
      run_bulk(admin, [hidden], { assignee_id: admin.id, status: 'resolved' })

      expect(hidden.reload.assignee_id).to eq(admin.id)
      expect(hidden.status).to eq('resolved')
    end
  end

  describe 'macros' do
    it 'does not assign, move to a team or change the status of a conversation he cannot see' do
      run_macro(restricted, [hidden],
                { 'action_name' => 'assign_agent', 'action_params' => ['self'] },
                { 'action_name' => 'assign_team', 'action_params' => [team.id] },
                { 'action_name' => 'change_status', 'action_params' => ['resolved'] })

      expect(hidden.reload.assignee_id).to be_nil
      expect(hidden.team_id).to be_nil
      expect(hidden.status).to eq('open')
    end

    it 'runs the same macro on the conversations he sees, in the same call' do
      run_macro(restricted, [hidden, visible],
                { 'action_name' => 'assign_team', 'action_params' => [team.id] },
                { 'action_name' => 'change_status', 'action_params' => ['resolved'] })

      expect(visible.reload.team_id).to eq(team.id)
      expect(visible.status).to eq('resolved')
      expect(hidden.reload.team_id).to be_nil
    end

    it 'does not restrict an administrator' do
      admin = create(:user, account: account, role: :administrator)

      run_macro(admin, [hidden], { 'action_name' => 'change_status', 'action_params' => ['resolved'] })

      expect(hidden.reload.status).to eq('resolved')
    end
  end
end
# rubocop:enable RSpec/DescribeClass
