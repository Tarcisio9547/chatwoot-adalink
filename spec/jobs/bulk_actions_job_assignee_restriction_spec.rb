require 'rails_helper'

# Ações em massa e atribuição: quem tem visão restrita só se atribui a conversa SEM responsável
# e só reatribui/tira o responsável se ele mesmo for o responsável atual. Vale em TODOS os canais
# (aqui, uma caixa de site). As outras ações do mesmo pedido (status, etiquetas) seguem normais.
# rubocop:disable RSpec/DescribeClass, RSpec/MultipleMemoizedHelpers -- cobre o job de upstream e o hook Enterprise.
describe 'BulkActionsJob assignee restriction' do
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
    role = create(:custom_role, account: account, permissions: %w[conversation_unassigned_manage])
    AccountUser.find_by(user: restricted, account: account).update!(role: :agent, custom_role: role)
    [owned_by_other, ownerless].each { |conversation| create(:conversation_participant, conversation: conversation, account: account, user: restricted) }
  end

  def run_bulk(user, conversations, fields)
    params = { type: 'Conversation', ids: conversations.map(&:display_id), fields: fields }
    BulkActionsJob.perform_now(account: account, params: params, user: user)
  end

  it 'does not let a restricted agent take a conversation that has another owner' do
    run_bulk(restricted, [owned_by_other], { assignee_id: restricted.id })

    expect(owned_by_other.reload.assignee_id).to eq(owner.id)
  end

  it 'does not let him remove another owner (assignee_id null)' do
    run_bulk(restricted, [owned_by_other], { assignee_id: nil })

    expect(owned_by_other.reload.assignee_id).to eq(owner.id)
  end

  it 'lets him take an ownerless conversation' do
    run_bulk(restricted, [ownerless], { assignee_id: restricted.id })

    expect(ownerless.reload.assignee_id).to eq(restricted.id)
  end

  it 'does not let him give an ownerless conversation to someone else' do
    run_bulk(restricted, [ownerless], { assignee_id: colleague.id })

    expect(ownerless.reload.assignee_id).to be_nil
  end

  it 'lets him hand over or drop a conversation he owns' do
    run_bulk(restricted, [mine], { assignee_id: colleague.id })
    expect(mine.reload.assignee_id).to eq(colleague.id)

    mine.update!(assignee: restricted)
    run_bulk(restricted, [mine], { assignee_id: nil })
    expect(mine.reload.assignee_id).to be_nil
  end

  it 'applies the allowed ones and skips the others in the same call' do
    run_bulk(restricted, [owned_by_other, ownerless, mine], { assignee_id: restricted.id })

    expect(owned_by_other.reload.assignee_id).to eq(owner.id)
    expect(ownerless.reload.assignee_id).to eq(restricted.id)
    expect(mine.reload.assignee_id).to eq(restricted.id)
  end

  it 'still applies the other fields of the same request to what he sees (status), without the assignee' do
    run_bulk(restricted, [owned_by_other], { assignee_id: restricted.id, status: 'resolved' })

    expect(owned_by_other.reload.status).to eq('resolved')
    expect(owned_by_other.assignee_id).to eq(owner.id)
  end

  it 'does not touch the assignee when the request does not ask for it' do
    run_bulk(restricted, [owned_by_other], { status: 'resolved' })

    expect(owned_by_other.reload.assignee_id).to eq(owner.id)
    expect(owned_by_other.status).to eq('resolved')
  end

  it 'keeps the previous behaviour for an administrator' do
    run_bulk(admin, [owned_by_other, ownerless], { assignee_id: admin.id })

    expect([owned_by_other, ownerless].map { |conversation| conversation.reload.assignee_id }).to all(eq(admin.id))
  end

  it 'keeps the previous behaviour for an agent without custom role' do
    run_bulk(colleague, [owned_by_other], { assignee_id: colleague.id })

    expect(owned_by_other.reload.assignee_id).to eq(colleague.id)
  end

  it 'keeps the previous behaviour for the "Todas" role' do
    role = create(:custom_role, account: account, permissions: %w[conversation_manage])
    AccountUser.find_by(user: restricted, account: account).update!(role: :agent, custom_role: role)

    run_bulk(restricted, [owned_by_other], { assignee_id: restricted.id })

    expect(owned_by_other.reload.assignee_id).to eq(restricted.id)
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleMemoizedHelpers
