require 'rails_helper'

# Macros: a ação "atribuir agente" segue a mesma regra de quem tem visão restrita (só toma a
# conversa sem responsável; só reatribui ou tira o responsável se ele for o responsável atual).
# Vale em TODOS os canais (aqui, uma caixa de site). Admin, agente sem custom_role e "Todas"
# seguem como antes; as outras ações da mesma macro continuam rodando.
# rubocop:disable RSpec/DescribeClass, RSpec/MultipleMemoizedHelpers -- cobre o job e o serviço de macro.
describe 'Macro assign_agent restriction' do
  let!(:account) { create(:account) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:restricted) { create(:user, account: account, role: :agent) }
  let!(:owner) { create(:user, account: account, role: :agent) }
  let!(:colleague) { create(:user, account: account, role: :agent) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:owned_by_other) { create(:conversation, account: account, inbox: inbox, assignee: owner, status: :open) }
  let!(:ownerless) { create(:conversation, account: account, inbox: inbox, assignee: nil, status: :open) }
  let!(:mine) { create(:conversation, account: account, inbox: inbox, assignee: restricted, status: :open) }

  before do
    [restricted, owner, colleague].each { |user| create(:inbox_member, user: user, inbox: inbox) }
    role = create(:custom_role, account: account, permissions: %w[conversation_participating_manage])
    AccountUser.find_by(user: restricted, account: account).update!(role: :agent, custom_role: role)
    [owned_by_other, ownerless].each { |conversation| create(:conversation_participant, conversation: conversation, account: account, user: restricted) }
  end

  def run_macro(user, conversations, *actions)
    macro = create(:macro, account: account, actions: actions)
    MacrosExecutionJob.perform_now(macro, conversation_ids: conversations.map(&:display_id), user: user)
  end

  def assign(param)
    { 'action_name' => 'assign_agent', 'action_params' => [param] }
  end

  it 'does not assign a restricted agent to a conversation that has another owner ("self")' do
    run_macro(restricted, [owned_by_other], assign('self'))

    expect(owned_by_other.reload.assignee_id).to eq(owner.id)
  end

  it 'does not let him assign an owned conversation to a colleague or unassign it' do
    run_macro(restricted, [owned_by_other], assign(colleague.id))
    expect(owned_by_other.reload.assignee_id).to eq(owner.id)

    run_macro(restricted, [owned_by_other], assign('nil'))
    expect(owned_by_other.reload.assignee_id).to eq(owner.id)
  end

  it 'lets him take an ownerless conversation' do
    run_macro(restricted, [ownerless], assign('self'))

    expect(ownerless.reload.assignee_id).to eq(restricted.id)
  end

  it 'does not let him give an ownerless conversation to someone else' do
    run_macro(restricted, [ownerless], assign(colleague.id))

    expect(ownerless.reload.assignee_id).to be_nil
  end

  it 'lets him hand over or drop a conversation he owns' do
    run_macro(restricted, [mine], assign(colleague.id))
    expect(mine.reload.assignee_id).to eq(colleague.id)

    mine.update!(assignee: restricted)
    run_macro(restricted, [mine], assign('nil'))
    expect(mine.reload.assignee_id).to be_nil
  end

  it 'still runs the other actions of the same macro when the assignment is not allowed' do
    run_macro(restricted, [owned_by_other], assign('self'), { 'action_name' => 'change_status', 'action_params' => ['resolved'] })

    expect(owned_by_other.reload.status).to eq('resolved')
    expect(owned_by_other.assignee_id).to eq(owner.id)
  end

  it 'keeps the previous behaviour for an administrator, an agent without custom role and the "Todas" role' do
    run_macro(admin, [owned_by_other], assign('self'))
    expect(owned_by_other.reload.assignee_id).to eq(admin.id)

    run_macro(colleague, [owned_by_other], assign('self'))
    expect(owned_by_other.reload.assignee_id).to eq(colleague.id)

    all_role = create(:custom_role, account: account, permissions: %w[conversation_manage])
    AccountUser.find_by(user: restricted, account: account).update!(role: :agent, custom_role: all_role)
    run_macro(restricted, [owned_by_other], assign('self'))
    expect(owned_by_other.reload.assignee_id).to eq(restricted.id)
  end

  it 'does not restrict automation rules (they run as the system, not as a user)' do
    service = ActionService.new(owned_by_other)

    service.assign_agent([colleague.id])

    expect(owned_by_other.reload.assignee_id).to eq(colleague.id)
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleMemoizedHelpers
