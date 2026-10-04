require 'rails_helper'
require Rails.root.join('db/migrate/20261004153847_remove_stale_restricted_conversation_participants.rb')

# Backfill: antes de "participante enxerga a conversa", o Chatwoot já fazia de todo responsável
# um participante e nunca o removia. Para um usuário de visão RESTRITA (custom_role sem
# conversation_manage), a linha que sobra de um ex-responsável viraria acesso na lista. A
# migração apaga essas linhas, exceto as do responsável ATUAL, e deixa intactas as de
# administrador, agente sem custom_role e custom_role com conversation_manage.
# rubocop:disable RSpec/MultipleMemoizedHelpers -- o cenário precisa de um usuário por papel.
describe RemoveStaleRestrictedConversationParticipants do
  let(:migration) { described_class.new }
  let!(:account) { create(:account) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:restricted_unassigned) { create(:user, account: account, role: :agent) }
  let!(:restricted_participating) { create(:user, account: account, role: :agent) }
  let!(:manager) { create(:user, account: account, role: :agent) }
  let!(:plain_agent) { create(:user, account: account, role: :agent) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: restricted_unassigned) }
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
    give_role(manager, %w[conversation_manage conversation_participating_manage])
    [restricted_unassigned, restricted_participating, manager, plain_agent, admin].each { |user| participate(user) }
  end

  it 'removes the rows of restricted users who are not the current assignee' do
    run_migration

    expect(participants).not_to include(restricted_participating.id)
  end

  it 'keeps the row of the restricted user who IS the current assignee' do
    run_migration

    expect(participants).to include(restricted_unassigned.id)
  end

  it 'keeps the rows of administrators, agents without custom role and "Todas" roles' do
    run_migration

    expect(participants).to include(admin.id, plain_agent.id, manager.id)
  end

  it 'removes a restricted user from conversations assigned to someone else too (the old ex-assignee case)' do
    participate(restricted_unassigned, other_conversation)

    run_migration

    expect(participants(other_conversation)).not_to include(restricted_unassigned.id)
    expect(participants(conversation)).to include(restricted_unassigned.id)
  end

  it 'removes a restricted user from an unassigned conversation' do
    unassigned = create(:conversation, account: account, inbox: inbox, assignee: nil)
    participate(restricted_participating, unassigned)

    run_migration

    expect(participants(unassigned)).to be_empty
  end

  it 'looks at the role in the account of the conversation, not in another account' do
    other_account = create(:account)
    create(:account_user, account: other_account, user: restricted_participating, role: :agent)
    other_inbox = create(:inbox, account: other_account)
    foreign_conversation = create(:conversation, account: other_account, inbox: other_inbox, assignee: nil)
    participate(restricted_participating, foreign_conversation)

    run_migration

    expect(participants(foreign_conversation)).to eq([restricted_participating.id])
    expect(participants(conversation)).not_to include(restricted_participating.id)
  end

  it 'keeps the row of an administrator even if it still carries a leftover custom_role' do
    role = create(:custom_role, account: account, permissions: %w[conversation_unassigned_manage])
    AccountUser.find_by(user: admin, account: account).update_columns(custom_role_id: role.id) # rubocop:disable Rails/SkipsModelValidations

    run_migration

    expect(participants).to include(admin.id)
  end

  it 'removes a row whose custom_role has no permissions at all' do
    empty_role_user = create(:user, account: account, role: :agent)
    AccountUser.find_by(user: empty_role_user, account: account).update!(role: :agent, custom_role: create(:custom_role, account: account, permissions: []))
    participate(empty_role_user)

    run_migration

    expect(participants).not_to include(empty_role_user.id)
  end

  it 'leaves alone a participant who has no AccountUser in the conversation account (nothing to prove it is restricted)' do
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

  it 'logs how many rows it removed, per account' do
    allow(Rails.logger).to receive(:info)

    run_migration

    expect(Rails.logger).to have_received(:info).with(/account #{account.id}: removed 1 /).at_least(:once)
    expect(Rails.logger).to have_received(:info).with(/total removed: 1/)
  end

  it 'does not touch rows when none matches' do
    ConversationParticipant.where(user_id: restricted_participating.id).delete_all

    expect { run_migration }.not_to(change(ConversationParticipant, :count))
  end

  it 'is irreversible on purpose (down does nothing)' do
    expect { migration.suppress_messages { migration.down } }.not_to change(ConversationParticipant, :count)
  end
end
# rubocop:enable RSpec/MultipleMemoizedHelpers
