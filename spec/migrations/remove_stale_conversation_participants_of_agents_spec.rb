require 'rails_helper'
require Rails.root.join('db/migrate/20261004153847_remove_stale_conversation_participants_of_agents.rb')

# Backfill: antes de "participante enxerga a conversa", o Chatwoot já fazia de todo responsável
# um participante e nunca o removia. Quando uma conta passa a usar visão restrita (os grupos do
# CRM criam custom_role depois), as linhas que sobraram de ex-responsáveis virariam acesso. Por
# isso o critério NÃO depende do papel de hoje: a migração apaga as linhas de AGENTES (role = 0,
# com ou sem custom_role) que não são o responsável atual da conversa, e mantém as de
# administrador (role = 1) e as do responsável atual.
describe RemoveStaleConversationParticipantsOfAgents do
  let(:migration) { described_class.new }
  let!(:account) { create(:account) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:assignee) { create(:user, account: account, role: :agent) }
  let!(:plain_agent) { create(:user, account: account, role: :agent) }
  let!(:restricted_unassigned) { create(:user, account: account, role: :agent) }
  let!(:restricted_participating) { create(:user, account: account, role: :agent) }
  let!(:manager_role_agent) { create(:user, account: account, role: :agent) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: assignee) }
  let!(:other_conversation) { create(:conversation, account: account, inbox: inbox, assignee: plain_agent) }

  def give_role(user, permissions, target_account: account)
    role = create(:custom_role, account: target_account, permissions: permissions)
    AccountUser.find_by(user: user, account: target_account).update!(role: :agent, custom_role: role)
  end

  def participants(target = conversation)
    ConversationParticipant.where(conversation_id: target.id).pluck(:user_id)
  end

  def participate(user, target = conversation)
    ConversationParticipant.create!(conversation: target, account: target.account, user: user)
  end

  def run_migration
    migration.suppress_messages { migration.up }
  end

  before do
    give_role(restricted_unassigned, %w[conversation_unassigned_manage])
    give_role(restricted_participating, %w[conversation_participating_manage])
    give_role(manager_role_agent, %w[conversation_manage])
    [assignee, plain_agent, restricted_unassigned, restricted_participating, manager_role_agent, admin].each { |user| participate(user) }
  end

  it 'removes the row of an agent without custom role who is not the current assignee (the case that matters today)' do
    run_migration

    expect(participants).not_to include(plain_agent.id)
  end

  it 'removes the rows of agents with a restricted role, whatever the tier' do
    run_migration

    expect(participants).not_to include(restricted_unassigned.id, restricted_participating.id)
  end

  it 'removes the row of an agent with the "Todas" role too: the criterion does not depend on today role' do
    run_migration

    expect(participants).not_to include(manager_role_agent.id)
  end

  it 'keeps the row of the current assignee, with or without custom role' do
    give_role(assignee, %w[conversation_unassigned_manage])

    run_migration

    expect(participants).to include(assignee.id)
  end

  it 'keeps the rows of administrators, assignee or not' do
    run_migration

    expect(participants).to include(admin.id)
    expect(participants).to contain_exactly(assignee.id, admin.id)
  end

  it 'keeps the row of an administrator even if it still carries a leftover custom_role' do
    role = create(:custom_role, account: account, permissions: %w[conversation_unassigned_manage])
    AccountUser.find_by(user: admin, account: account).update_columns(custom_role_id: role.id) # rubocop:disable Rails/SkipsModelValidations

    run_migration

    expect(participants).to include(admin.id)
  end

  it 'removes an agent from conversations assigned to someone else too (the old ex-assignee case) and keeps the assignee of each' do
    participate(assignee, other_conversation)
    participate(plain_agent, other_conversation) # o responsavel desta conversa tambem participa

    run_migration

    expect(participants(other_conversation)).not_to include(assignee.id)
    expect(participants(other_conversation)).to include(plain_agent.id)
  end

  it 'removes an agent from an unassigned conversation and keeps the administrator there' do
    unassigned = create(:conversation, account: account, inbox: inbox, assignee: nil)
    participate(plain_agent, unassigned)
    participate(admin, unassigned)

    run_migration

    expect(participants(unassigned)).to eq([admin.id])
  end

  it 'looks at the role in the account of the conversation, not in another account' do
    other_account = create(:account)
    create(:account_user, account: other_account, user: plain_agent, role: :administrator)
    other_inbox = create(:inbox, account: other_account)
    admin_here = create(:conversation, account: other_account, inbox: other_inbox, assignee: nil)
    participate(plain_agent, admin_here)

    run_migration

    expect(participants(admin_here)).to eq([plain_agent.id])
    expect(participants(conversation)).not_to include(plain_agent.id)
  end

  it 'leaves alone a participant who has no AccountUser in the conversation account (nothing says he is an agent)' do
    stranger = create(:user, account: create(:account), role: :agent)
    participate(stranger)

    run_migration

    expect(participants).to include(stranger.id)
  end

  it 'is idempotent: a second run removes nothing more' do
    run_migration
    after_first = ConversationParticipant.order(:id).pluck(:id)

    run_migration

    expect(ConversationParticipant.order(:id).pluck(:id)).to eq(after_first)
  end

  it 'logs how many rows it removed, per account, and which ones' do
    allow(Rails.logger).to receive(:info)

    run_migration

    expect(Rails.logger).to have_received(:info).with(/account #{account.id}: removed 4 /).at_least(:once)
    expect(Rails.logger).to have_received(:info).with(/account #{account.id}: removed rows .*#{plain_agent.id}/).at_least(:once)
    expect(Rails.logger).to have_received(:info).with(/total removed: 4/)
  end

  it 'does not touch rows when none matches' do
    ConversationParticipant.where.not(user_id: [assignee.id, admin.id]).delete_all

    expect { run_migration }.not_to(change(ConversationParticipant, :count))
  end

  it 'is irreversible on purpose (down does nothing)' do
    expect { migration.suppress_messages { migration.down } }.not_to change(ConversationParticipant, :count)
  end
end
