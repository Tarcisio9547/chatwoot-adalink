require 'rails_helper'

# As ações em massa atuam em qualquer display_id enviado. Numa caixa WhatsApp, o
# job só pode agir nas conversas que o usuário enxerga pelo papel: um Setor não
# se atribui (assignee_id = ele mesmo) à conversa de um colega pra passar a
# enxergá-la. Outras caixas seguem como antes.
# rubocop:disable RSpec/DescribeClass -- cobre o job de upstream e o override Enterprise.
describe 'BulkActionsJob role visibility' do
  let!(:account) { create(:account) }
  let!(:setor_agent) { create(:user, account: account, role: :agent) }
  let!(:colleague) { create(:user, account: account, role: :agent) }
  let!(:setor_role) { create(:custom_role, account: account, permissions: %w[conversation_participating_manage]) }
  let!(:whatsapp_inbox) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox
  end
  let!(:colleague_conversation) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: colleague, status: :open) }
  let!(:own_conversation) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: setor_agent, status: :open) }

  before do
    [setor_agent, colleague].each { |user| create(:inbox_member, user: user, inbox: whatsapp_inbox) }
    AccountUser.find_by(user: setor_agent, account: account).update!(custom_role: setor_role)
  end

  def run_bulk(user, conversations, fields)
    params = { type: 'Conversation', ids: conversations.map(&:display_id), fields: fields }
    BulkActionsJob.perform_now(account: account, params: params, user: user)
  end

  it 'does not let a Setor agent take a colleague conversation (assignee_id = themselves)' do
    run_bulk(setor_agent, [colleague_conversation], { assignee_id: setor_agent.id })

    expect(colleague_conversation.reload.assignee_id).to eq(colleague.id)
  end

  it 'does not change the status, labels or snooze of a colleague conversation' do
    params = { type: 'Conversation', ids: [colleague_conversation.display_id], fields: { status: 'resolved' },
               labels: { add: ['vendas'] } }
    create(:label, account: account, title: 'vendas')

    BulkActionsJob.perform_now(account: account, params: params, user: setor_agent)

    expect(colleague_conversation.reload.status).to eq('open')
    expect(colleague_conversation.label_list).to be_empty
  end

  it 'still updates the conversations the Setor agent sees, in the same call' do
    run_bulk(setor_agent, [colleague_conversation, own_conversation], { status: 'resolved' })

    expect(own_conversation.reload.status).to eq('resolved')
    expect(colleague_conversation.reload.status).to eq('open')
  end

  it 'updates any conversation for an administrator' do
    admin = create(:user, account: account, role: :administrator)

    run_bulk(admin, [colleague_conversation], { assignee_id: admin.id })

    expect(colleague_conversation.reload.assignee_id).to eq(admin.id)
  end

  # A visibilidade por papel de rótulos e soneca só filtra caixas WhatsApp (outras caixas seguem como
  # estavam). Já responsável, time e status valem em TODOS os canais: quem tem visão restrita só age no
  # que enxerga, e a atribuição só vale conversa sem dono ou do próprio dono (ver
  # spec/jobs/bulk_actions_job_assignee_restriction_spec.rb e bulk_and_macro_invisible_conversations_spec.rb).
  it 'does not change assignee or status of a colleague conversation on other channels either, but still applies labels' do
    other_inbox = create(:inbox, account: account)
    create(:inbox_member, user: setor_agent, inbox: other_inbox)
    other = create(:conversation, account: account, inbox: other_inbox, assignee: colleague, status: :open)
    create(:label, account: account, title: 'vendas')

    BulkActionsJob.perform_now(account: account, user: setor_agent,
                               params: { type: 'Conversation', ids: [other.display_id],
                                         fields: { assignee_id: setor_agent.id, status: 'resolved' } })
    BulkActionsJob.perform_now(account: account, user: setor_agent,
                               params: { type: 'Conversation', ids: [other.display_id], labels: { add: ['vendas'] } })

    expect(other.reload.status).to eq('open')
    expect(other.assignee_id).to eq(colleague.id)
    expect(other.label_list).to eq(['vendas'])
  end
end
# rubocop:enable RSpec/DescribeClass
