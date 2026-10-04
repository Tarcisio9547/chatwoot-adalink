require 'rails_helper'
require Rails.root.join('db/migrate/20261004153847_remove_stale_conversation_participants_of_agents.rb')

# Backfill: antes de "participante enxerga a conversa", o Chatwoot já fazia de todo responsável
# um participante e nunca o removia. Quando uma conta passa a usar visão restrita (os grupos do
# CRM criam custom_role depois), as linhas que sobraram de ex-responsáveis virariam acesso. Por
# isso o critério NÃO depende do papel de hoje: a migração apaga as linhas de AGENTES (role = 0,
# com ou sem custom_role) que não são o responsável atual E são membros da caixa da conversa.
#
# Fica de fora quem NÃO é membro da caixa: é o gestor que o CRM adiciona como participante de uma
# conversa do WhatsApp Pessoal (caixa Channel::Api) e cujo acesso vem SÓ da participação. Também
# ficam o administrador (role = 1) e o responsável atual.
#
# Antes de apagar, copia as linhas para conversation_participants_backup_20261004 (mesma
# transação); o down restaura a partir dela.
# rubocop:disable RSpec/MultipleMemoizedHelpers -- o cenário precisa de um usuário por papel.
describe RemoveStaleConversationParticipantsOfAgents do
  let(:migration) { described_class.new }
  let(:backup) { 'conversation_participants_backup_20261004' }
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

  def backed_up(target = conversation)
    ActiveRecord::Base.connection.select_all("SELECT * FROM #{backup} WHERE conversation_id = #{target.id}").to_a
  end

  def run_migration
    migration.suppress_messages { migration.up }
  end

  before do
    give_role(restricted_unassigned, %w[conversation_unassigned_manage])
    give_role(restricted_participating, %w[conversation_participating_manage])
    give_role(manager_role_agent, %w[conversation_manage])
    [assignee, plain_agent, restricted_unassigned, restricted_participating, manager_role_agent].each do |user|
      create(:inbox_member, inbox: inbox, user: user)
    end
    [assignee, plain_agent, restricted_unassigned, restricted_participating, manager_role_agent, admin].each { |user| participate(user) }
  end

  it 'removes the row of an agent without custom role who is a member of the inbox and not the assignee (the case that matters today)' do
    run_migration

    expect(participants).not_to include(plain_agent.id)
  end

  it 'removes the rows of member agents with a restricted role, whatever the tier' do
    run_migration

    expect(participants).not_to include(restricted_unassigned.id, restricted_participating.id)
  end

  it 'removes the row of a member agent with the "Todas" role too: the criterion does not depend on today role' do
    run_migration

    expect(participants).not_to include(manager_role_agent.id)
  end

  it 'keeps the row of the current assignee, with or without custom role' do
    give_role(assignee, %w[conversation_unassigned_manage])

    run_migration

    expect(participants).to include(assignee.id)
  end

  it 'keeps the rows of administrators, member or not' do
    create(:inbox_member, inbox: inbox, user: admin)

    run_migration

    expect(participants).to contain_exactly(assignee.id, admin.id)
  end

  it 'keeps the row of an administrator even if it still carries a leftover custom_role' do
    role = create(:custom_role, account: account, permissions: %w[conversation_unassigned_manage])
    AccountUser.find_by(user: admin, account: account).update_columns(custom_role_id: role.id) # rubocop:disable Rails/SkipsModelValidations
    create(:inbox_member, inbox: inbox, user: admin)

    run_migration

    expect(participants).to include(admin.id)
  end

  # O CRM (wa-pessoal-mark-work / wa-classifier-confirm) adiciona o gestor direto do corretor como
  # participante de uma conversa da caixa pessoal. Ele é agente (role 0), não é membro da caixa nem
  # responsável: o acesso dele vem SÓ da participação. Não pode sair no backfill.
  context 'with the manager the CRM adds to a personal WhatsApp conversation (Channel::Api inbox)' do
    let!(:personal_inbox) { create(:inbox, account: account, channel: create(:channel_api, account: account)) }
    let!(:broker) { create(:user, account: account, role: :agent) }
    let!(:personal_conversation) { create(:conversation, account: account, inbox: personal_inbox, assignee: broker) }
    let!(:manager) { create(:user, account: account, role: :agent) }
    let!(:manager_with_role) { create(:user, account: account, role: :agent) }

    before do
      create(:inbox_member, inbox: personal_inbox, user: broker)
      give_role(manager_with_role, %w[conversation_participating_manage])
      [manager, manager_with_role, broker].each { |user| participate(user, personal_conversation) }
    end

    it 'keeps the manager (no custom role) who is not a member of the personal inbox' do
      run_migration

      expect(participants(personal_conversation)).to include(manager.id)
    end

    it 'keeps the manager with a restricted role ("Minhas") who is not a member of the personal inbox' do
      run_migration

      expect(participants(personal_conversation)).to include(manager_with_role.id)
    end

    it 'keeps the broker (assignee) and still removes an ex-assignee who is a member of that same inbox' do
      ex_assignee = create(:user, account: account, role: :agent)
      create(:inbox_member, inbox: personal_inbox, user: ex_assignee)
      participate(ex_assignee, personal_conversation)

      run_migration

      expect(participants(personal_conversation)).to contain_exactly(broker.id, manager.id, manager_with_role.id)
    end

    it 'does not copy the manager to the backup' do
      run_migration

      expect(backed_up(personal_conversation)).to be_empty
    end
  end

  it 'removes a member agent from conversations assigned to someone else too (the old ex-assignee case) and keeps the assignee of each' do
    participate(assignee, other_conversation)
    participate(plain_agent, other_conversation) # o responsavel desta conversa tambem participa

    run_migration

    expect(participants(other_conversation)).not_to include(assignee.id)
    expect(participants(other_conversation)).to include(plain_agent.id)
  end

  it 'removes a member agent from an unassigned conversation and keeps the administrator there' do
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
    create(:inbox_member, inbox: other_inbox, user: plain_agent)
    admin_here = create(:conversation, account: other_account, inbox: other_inbox, assignee: nil)
    participate(plain_agent, admin_here)

    run_migration

    expect(participants(admin_here)).to eq([plain_agent.id])
    expect(participants(conversation)).not_to include(plain_agent.id)
  end

  it 'leaves alone a participant who has no AccountUser in the conversation account (nothing says he is an agent)' do
    stranger = create(:user, account: create(:account), role: :agent)
    create(:inbox_member, inbox: inbox, user: stranger)
    participate(stranger)

    run_migration

    expect(participants).to include(stranger.id)
  end

  it 'is idempotent: a second run removes nothing more' do
    run_migration
    after_first = ConversationParticipant.order(:id).pluck(:id)
    backup_after_first = backed_up.size

    run_migration

    expect(ConversationParticipant.order(:id).pluck(:id)).to eq(after_first)
    expect(backed_up.size).to eq(backup_after_first)
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

  describe 'backup before the DELETE' do
    it 'copies every removed row, with the same columns plus removed_at, and only those' do
      removed = ConversationParticipant.where(conversation_id: conversation.id,
                                              user_id: [plain_agent.id, restricted_unassigned.id, restricted_participating.id, manager_role_agent.id])
                                       .index_by(&:user_id)

      run_migration

      saved = backed_up.index_by { |row| row['user_id'] }
      expect(saved.keys).to contain_exactly(*removed.keys)
      removed.each do |user_id, original|
        expect(saved[user_id].slice('id', 'account_id', 'conversation_id', 'user_id')).to eq(
          'id' => original.id, 'account_id' => original.account_id, 'conversation_id' => original.conversation_id, 'user_id' => user_id
        )
        expect(saved[user_id]['created_at']).to be_present
        expect(saved[user_id]['removed_at']).to be_present
      end
    end

    it 'does not copy what stays (assignee, administrator)' do
      run_migration

      expect(backed_up.pluck('user_id')).not_to include(assignee.id, admin.id)
    end

    it 'runs inside the migration transaction (DDL transaction not disabled)' do
      expect(described_class.disable_ddl_transaction).to be_falsey
    end
  end

  describe '#down' do
    it 'restores the removed rows from the backup, with their original ids' do
      original_ids = participants.sort
      original_row_ids = ConversationParticipant.where(conversation_id: conversation.id).order(:id).pluck(:id)
      run_migration
      expect(participants.sort).not_to eq(original_ids)

      migration.suppress_messages { migration.down }

      expect(participants.sort).to eq(original_ids)
      expect(ConversationParticipant.where(conversation_id: conversation.id).order(:id).pluck(:id)).to eq(original_row_ids)
    end

    it 'keeps the backup table (it is the evidence; drop it by hand when no longer needed)' do
      run_migration
      migration.suppress_messages { migration.down }

      expect(backed_up).not_to be_empty
    end

    it 'does not duplicate a participation that was recreated by hand meanwhile' do
      run_migration
      participate(plain_agent)

      expect { migration.suppress_messages { migration.down } }.not_to raise_error
      expect(participants.count(plain_agent.id)).to eq(1)
    end

    it 'does nothing when the migration never ran (no backup table)' do
      expect { migration.suppress_messages { migration.down } }.not_to change(ConversationParticipant, :count)
    end
  end
end
# rubocop:enable RSpec/MultipleMemoizedHelpers
