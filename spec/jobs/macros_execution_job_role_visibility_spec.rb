require 'rails_helper'

# A macro executa em qualquer display_id enviado. Numa caixa WhatsApp, o job só
# pode agir nas conversas que o usuário enxerga pelo papel: um Setor não manda a
# transcrição da conversa de um colega por e-mail nem se atribui a ela. Outras
# caixas seguem como antes.
# rubocop:disable RSpec/DescribeClass -- cobre o job de upstream e o override Enterprise.
describe 'MacrosExecutionJob role visibility' do
  let!(:account) { create(:account) }
  let!(:setor_agent) { create(:user, account: account, role: :agent) }
  let!(:colleague) { create(:user, account: account, role: :agent) }
  let!(:setor_role) { create(:custom_role, account: account, permissions: %w[conversation_participating_manage]) }
  let!(:whatsapp_inbox) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox
  end
  let!(:colleague_conversation) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: colleague) }
  let!(:own_conversation) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: setor_agent) }
  let(:macro) do
    create(:macro, account: account, actions: [
             { 'action_name' => 'assign_agent', 'action_params' => ['self'] },
             { 'action_name' => 'send_email_transcript', 'action_params' => ['alvo@example.com'] }
           ])
  end

  before do
    [setor_agent, colleague].each { |user| create(:inbox_member, user: user, inbox: whatsapp_inbox) }
    AccountUser.find_by(user: setor_agent, account: account).update!(custom_role: setor_role)
    allow(macro.account).to receive(:email_transcript_enabled?).and_return(true)
  end

  def run_macro(conversations)
    MacrosExecutionJob.perform_now(macro, conversation_ids: conversations.map(&:display_id), user: setor_agent)
  end

  it 'does not assign the Setor agent to a colleague conversation' do
    run_macro([colleague_conversation])

    expect(colleague_conversation.reload.assignee_id).to eq(colleague.id)
  end

  it 'does not email the transcript of a colleague conversation' do
    expect { run_macro([colleague_conversation]) }.not_to have_enqueued_mail(ConversationReplyMailer, :conversation_transcript)
  end

  it 'still runs on the conversations the Setor agent sees, in the same call' do
    colleague_conversation.update!(assignee: colleague)
    other_own = create(:conversation, account: account, inbox: whatsapp_inbox, assignee: nil)
    create(:conversation_participant, conversation: other_own, account: account, user: setor_agent)

    expect { run_macro([colleague_conversation, own_conversation, other_own]) }
      .to have_enqueued_mail(ConversationReplyMailer, :conversation_transcript).twice
    expect(colleague_conversation.reload.assignee_id).to eq(colleague.id)
  end

  it 'runs on every conversation for an administrator' do
    admin = create(:user, account: account, role: :administrator)

    MacrosExecutionJob.perform_now(macro, conversation_ids: [colleague_conversation.display_id], user: admin)

    expect(colleague_conversation.reload.assignee_id).to eq(admin.id)
  end

  it 'keeps running on other channels whatever the role (current behaviour, unchanged)' do
    other_inbox = create(:inbox, account: account)
    create(:inbox_member, user: setor_agent, inbox: other_inbox)
    other = create(:conversation, account: account, inbox: other_inbox, assignee: colleague)

    run_macro([other])

    expect(other.reload.assignee_id).to eq(setor_agent.id)
  end
end
# rubocop:enable RSpec/DescribeClass
