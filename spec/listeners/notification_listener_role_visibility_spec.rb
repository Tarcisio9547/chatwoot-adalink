require 'rails_helper'

# Adalink: #2084 - na caixa WhatsApp Cloud, o aviso de conversa criada vai so
# para membros cujo papel permite ver a conversa. Outras caixas continuam
# avisando todos os membros, igual ao comportamento anterior. Arquivo
# separado de notification_listener_spec.rb para nao herdar memoized
# helpers do describe principal (first_agent, agent_with_out_notification,
# conversation) que nao sao usados aqui.
describe NotificationListener do
  let(:listener) { described_class.instance }
  let(:event_name) { :'conversation.created' }
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account: account) }
  let!(:whatsapp_inbox) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox
  end
  let!(:setor_role) { create(:custom_role, account: account, permissions: %w[conversation_participating_manage]) }
  let!(:all_role) { create(:custom_role, account: account, permissions: %w[conversation_manage]) }
  let!(:setor_member) { create(:user, account: account) }
  let!(:all_member) { create(:user, account: account) }
  let!(:whatsapp_conversation) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: user) }

  before do
    create(:inbox_member, user: setor_member, inbox: whatsapp_inbox)
    create(:inbox_member, user: all_member, inbox: whatsapp_inbox)
    create(:inbox_member, user: user, inbox: whatsapp_inbox)

    [setor_member, all_member, user].each do |member|
      setting = member.notification_settings.find_by(account: account)
      setting.selected_email_flags = [:email_conversation_creation]
      setting.selected_push_flags = []
      setting.save!
    end

    AccountUser.find_by(user: setor_member, account: account).update(custom_role: setor_role)
    AccountUser.find_by(user: all_member, account: account).update(custom_role: all_role)

    # HACK: to reload conversation inbox members (mesmo padrao do
    # action_cable_listener_spec.rb) - os membros sao adicionados acima,
    # depois da conversa ja ter carregado a associacao inbox.
    whatsapp_conversation.inbox.reload
  end

  describe 'conversation_created' do
    it 'does not notify a member with the Setor role about a colleague conversation' do
      event = Events::Base.new(event_name, Time.zone.now, conversation: whatsapp_conversation)

      listener.conversation_created(event)

      expect(setor_member.notifications.count).to eq(0)
    end

    it 'notifies a member with the "all conversations" role' do
      event = Events::Base.new(event_name, Time.zone.now, conversation: whatsapp_conversation)

      listener.conversation_created(event)

      expect(all_member.notifications.count).to eq(1)
    end

    it 'notifies the assignee' do
      event = Events::Base.new(event_name, Time.zone.now, conversation: whatsapp_conversation)

      listener.conversation_created(event)

      expect(user.notifications.count).to eq(1)
    end

    context 'when the inbox is not Channel::Whatsapp' do
      let!(:other_inbox) { create(:inbox, account: account) }
      let!(:other_inbox_conversation) { create(:conversation, account: account, inbox: other_inbox, assignee: user) }

      before do
        create(:inbox_member, user: setor_member, inbox: other_inbox)
        setting = setor_member.notification_settings.find_by(account: account)
        setting.selected_email_flags = [:email_conversation_creation]
        setting.selected_push_flags = []
        setting.save!
        other_inbox_conversation.inbox.reload
      end

      it 'keeps notifying every inbox member, role or not (current behaviour, unchanged)' do
        event = Events::Base.new(event_name, Time.zone.now, conversation: other_inbox_conversation)

        listener.conversation_created(event)

        expect(setor_member.notifications.count).to eq(1)
      end
    end
  end

  describe 'conversation_bot_handoff' do
    let(:bot_handoff_event_name) { :'conversation.bot_handoff' }

    it 'does not notify a member with the Setor role about a colleague conversation' do
      event = Events::Base.new(bot_handoff_event_name, Time.zone.now, conversation: whatsapp_conversation)

      listener.conversation_bot_handoff(event)

      expect(setor_member.notifications.count).to eq(0)
    end

    it 'notifies a member with the "all conversations" role' do
      event = Events::Base.new(bot_handoff_event_name, Time.zone.now, conversation: whatsapp_conversation)

      listener.conversation_bot_handoff(event)

      expect(all_member.notifications.count).to eq(1)
    end

    context 'when the inbox is not Channel::Whatsapp' do
      let!(:other_inbox) { create(:inbox, account: account) }
      let!(:other_inbox_conversation) { create(:conversation, account: account, inbox: other_inbox, assignee: user) }

      before do
        create(:inbox_member, user: setor_member, inbox: other_inbox)
        setting = setor_member.notification_settings.find_by(account: account)
        setting.selected_email_flags = [:email_conversation_creation]
        setting.selected_push_flags = []
        setting.save!
        other_inbox_conversation.inbox.reload
      end

      it 'keeps notifying every inbox member, role or not (current behaviour, unchanged)' do
        event = Events::Base.new(bot_handoff_event_name, Time.zone.now, conversation: other_inbox_conversation)

        listener.conversation_bot_handoff(event)

        expect(setor_member.notifications.count).to eq(1)
      end
    end
  end
end
