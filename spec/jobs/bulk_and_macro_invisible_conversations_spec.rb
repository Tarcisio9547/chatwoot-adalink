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

    it 'does not add or remove labels, nor snooze, on a conversation he cannot see' do
      create(:label, account: account, title: 'vendas')
      hidden.add_labels(['antiga'])

      run_bulk(restricted, [hidden], {}, { labels: { add: ['vendas'], remove: ['antiga'] }, snoozed_until: 2.days.from_now.iso8601 })

      expect(hidden.reload.label_list).to eq(['antiga'])
      expect(hidden.snoozed_until).to be_nil
    end

    it 'adds labels to the ones he sees, in the same call' do
      create(:label, account: account, title: 'vendas')

      run_bulk(restricted, [hidden, visible], {}, { labels: { add: ['vendas'] } })

      expect(visible.reload.label_list).to eq(['vendas'])
      expect(hidden.reload.label_list).to be_empty
    end

    it 'still adds labels for an administrator on any conversation' do
      admin = create(:user, account: account, role: :administrator)
      create(:label, account: account, title: 'vendas')

      run_bulk(admin, [hidden], {}, { labels: { add: ['vendas'] } })

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
      create(:team_member, team: team, user: restricted) # o dono continua no time: a troca não o tira da conversa
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

    # A macro pessoal rodava em display_id de colega: resolver, adiar, mandar mensagem (que sai pelo
    # número do colega no WhatsApp Pessoal), nota privada, transcrição e webhook. Agora o job só
    # executa nas conversas que o restrito enxerga, em qualquer canal.
    describe 'actions that used to run on any display_id (the job keeps only what he sees)' do
      it 'does not resolve a conversation he cannot see' do
        run_macro(restricted, [hidden], { 'action_name' => 'resolve_conversation', 'action_params' => [] })

        expect(hidden.reload.status).to eq('open')
      end

      it 'does not snooze a conversation he cannot see' do
        run_macro(restricted, [hidden], { 'action_name' => 'snooze_conversation', 'action_params' => [] })

        expect(hidden.reload.status).to eq('open')
      end

      it 'does not send a message (it would leave through the colleague number) or a private note into it' do
        run_macro(restricted, [hidden],
                  { 'action_name' => 'send_message', 'action_params' => ['oi, tudo bem?'] },
                  { 'action_name' => 'add_private_note', 'action_params' => ['nota'] })

        expect(hidden.messages.where.not(message_type: :activity)).to be_empty
      end

      it 'does not email the transcript or fire the webhook for it' do
        macro = create(:macro, account: account, actions: [
                         { 'action_name' => 'send_email_transcript', 'action_params' => ['alvo@example.com'] },
                         { 'action_name' => 'send_webhook_event', 'action_params' => ['https://example.com/hook'] }
                       ])
        allow(macro.account).to receive(:email_transcript_enabled?).and_return(true)
        allow(WebhookJob).to receive(:perform_later)

        expect { MacrosExecutionJob.perform_now(macro, conversation_ids: [hidden.display_id], user: restricted) }
          .not_to have_enqueued_mail(ConversationReplyMailer, :conversation_transcript)
        expect(WebhookJob).not_to have_received(:perform_later)
      end

      it 'works on the conversation he does see (resolve, snooze, send message), in the same call' do
        run_macro(restricted, [hidden, visible], { 'action_name' => 'send_message', 'action_params' => ['oi, tudo bem?'] })
        expect(visible.messages.outgoing.pluck(:content)).to eq(['oi, tudo bem?'])
        expect(hidden.messages.outgoing).to be_empty

        run_macro(restricted, [visible], { 'action_name' => 'snooze_conversation', 'action_params' => [] })
        expect(visible.reload.status).to eq('snoozed')

        run_macro(restricted, [visible], { 'action_name' => 'resolve_conversation', 'action_params' => [] })
        expect(visible.reload.status).to eq('resolved')
      end

      it 'lets him run them on a conversation he participates in even if the inbox is not his' do
        create(:conversation_participant, conversation: hidden, account: account, user: restricted)

        run_macro(restricted, [hidden], { 'action_name' => 'resolve_conversation', 'action_params' => [] })

        expect(hidden.reload.status).to eq('resolved')
      end

      it 'does not restrict an administrator or an agent without custom role' do
        admin = create(:user, account: account, role: :administrator)

        run_macro(admin, [hidden], { 'action_name' => 'resolve_conversation', 'action_params' => [] })

        expect(hidden.reload.status).to eq('resolved')
      end
    end
  end
end
# rubocop:enable RSpec/DescribeClass
