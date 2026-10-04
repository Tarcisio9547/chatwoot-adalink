require 'rails_helper'

# Uma notificação antiga continua apontando pra conversa. Se a conversa WhatsApp
# mudou de dono, o papel do dono da notificação pode ter deixado de enxergá-la,
# e o sino (GET /notifications) e o broadcast (notification.created/updated)
# não podem mostrar o conteúdo dela: nem push_message_body, nem as mensagens do
# primary_actor, nem a mensagem do secondary_actor.
describe 'Notification role visibility on WhatsApp conversations', type: :request do
  let!(:account) { create(:account) }
  let!(:agent_a) { create(:user, account: account, role: :agent) }
  let!(:agent_b) { create(:user, account: account, role: :agent) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:setor_role) { create(:custom_role, account: account, permissions: %w[conversation_participating_manage]) }
  let!(:sem_atendente_role) { create(:custom_role, account: account, permissions: %w[conversation_unassigned_manage]) }
  let!(:whatsapp_inbox) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox
  end
  let!(:conversation) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: agent_a) }
  let(:secret) { 'segredo do cliente X' }

  before do
    [agent_a, agent_b].each { |user| create(:inbox_member, user: user, inbox: whatsapp_inbox) }
    AccountUser.find_by(user: agent_a, account: account).update!(custom_role: setor_role)
    AccountUser.find_by(user: agent_b, account: account).update!(custom_role: setor_role)
  end

  def notifications_for(user)
    get "/api/v1/accounts/#{account.id}/notifications", headers: user.create_new_auth_token, as: :json
    response.parsed_body['data']['payload']
  end

  def leak_free?(payload_item)
    payload_item['push_message_body'].blank? &&
      payload_item['primary_actor']['messages'].blank? &&
      payload_item['secondary_actor'].to_s.exclude?(secret) &&
      payload_item.to_json.exclude?(secret)
  end

  context 'when the conversation was reassigned from A to B after A was notified' do
    let!(:notification) do
      create(:notification, account: account, user: agent_a, primary_actor: conversation, notification_type: 'conversation_assignment')
    end

    before do
      create(:message, account: account, inbox: whatsapp_inbox, conversation: conversation, content: 'oi antigo')
      conversation.update!(assignee: agent_b)
      create(:message, account: account, inbox: whatsapp_inbox, conversation: conversation, message_type: :incoming, content: secret)
    end

    it 'hides the conversation content from A in GET /notifications' do
      item = notifications_for(agent_a).first

      expect(item['id']).to eq(notification.id)
      expect(leak_free?(item)).to be true
    end

    it 'keeps the notification itself (id, type, conversation id) so the bell can still show it' do
      item = notifications_for(agent_a).first

      expect(item['notification_type']).to eq('conversation_assignment')
      expect(item['primary_actor_id']).to eq(conversation.id)
      expect(item['primary_actor']['id']).to eq(conversation.display_id)
    end

    it 'hides the content in the notification.updated broadcast payload' do
      payload = notification.reload.push_event_data

      expect(payload[:push_message_body]).to be_blank
      expect(payload[:primary_actor][:messages]).to be_blank
      expect(payload.to_json).not_to include(secret)
    end

    it 'does not leak through the ActionCable notification.updated event' do
      broadcasted = []
      allow(ActionCableBroadcastJob).to receive(:perform_later) { |_tokens, _event, data| broadcasted << data }

      ActionCableListener.instance.notification_updated(Events::Base.new(:'notification.updated', Time.zone.now, notification: notification))

      expect(broadcasted.to_json).not_to include(secret)
    end

    it 'still shows the content to the new assignee B, to an admin and to a user without role' do
      b_notification = create(:notification, account: account, user: agent_b, primary_actor: conversation,
                                             notification_type: 'conversation_assignment')
      admin_notification = create(:notification, account: account, user: admin, primary_actor: conversation,
                                                 notification_type: 'conversation_assignment')

      expect(b_notification.push_event_data[:push_message_body]).to include(secret)
      expect(admin_notification.push_event_data[:push_message_body]).to include(secret)
      expect(notifications_for(admin).first['push_message_body']).to include(secret)
    end
  end

  context 'when A is still the assignee' do
    it 'keeps showing the content to A' do
      create(:message, account: account, inbox: whatsapp_inbox, conversation: conversation, message_type: :incoming, content: secret)
      create(:notification, account: account, user: agent_a, primary_actor: conversation, notification_type: 'conversation_assignment')

      expect(notifications_for(agent_a).first['push_message_body']).to include(secret)
    end
  end

  context 'when a "Sem atendente" agent got a conversation_creation notification and the conversation then got an assignee' do
    let!(:unassigned) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: nil) }
    let!(:notification) do
      create(:notification, account: account, user: agent_a, primary_actor: unassigned, notification_type: 'conversation_creation')
    end

    before do
      create(:message, account: account, inbox: whatsapp_inbox, conversation: unassigned, message_type: :incoming, content: secret)
      AccountUser.find_by(user: agent_a, account: account).update!(custom_role: sem_atendente_role)
    end

    it 'shows the content while the conversation is unassigned' do
      expect(notifications_for(agent_a).first['push_message_body']).to include(secret)
    end

    it 'hides the content once the conversation is assigned to someone else' do
      unassigned.update!(assignee: agent_b)

      item = notifications_for(agent_a).first

      expect(leak_free?(item)).to be true
      expect(notification.reload.push_event_data[:push_message_body]).to be_blank
    end
  end

  context 'when a "Sem atendente" agent is an explicit participant of a conversation assigned to someone else' do
    let!(:assigned_to_b) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: agent_b) }
    let!(:notification) do
      create(:notification, account: account, user: agent_a, primary_actor: assigned_to_b, notification_type: 'conversation_assignment')
    end

    before do
      AccountUser.find_by(user: agent_a, account: account).update!(custom_role: sem_atendente_role)
      create(:message, account: account, inbox: whatsapp_inbox, conversation: assigned_to_b, message_type: :incoming, content: secret)
    end

    it 'hides the content while the agent is NOT a participant' do
      expect(leak_free?(notifications_for(agent_a).first)).to be true
    end

    it 'shows the content in GET /notifications once the agent is a participant' do
      create(:conversation_participant, conversation: assigned_to_b, account: account, user: agent_a)

      expect(notifications_for(agent_a).first['push_message_body']).to include(secret)
    end

    it 'shows the content in the notification.created broadcast payload once the agent is a participant' do
      create(:conversation_participant, conversation: assigned_to_b, account: account, user: agent_a)

      expect(notification.reload.push_event_data[:push_message_body]).to include(secret)
    end
  end

  context 'when the conversation is not on a WhatsApp inbox' do
    it 'keeps the content for A even after the reassignment (current behaviour, unchanged)' do
      other_inbox = create(:inbox, account: account)
      create(:inbox_member, user: agent_a, inbox: other_inbox)
      other = create(:conversation, account: account, inbox: other_inbox, assignee: agent_b)
      create(:message, account: account, inbox: other_inbox, conversation: other, message_type: :incoming, content: secret)
      create(:notification, account: account, user: agent_a, primary_actor: other, notification_type: 'conversation_assignment')

      expect(notifications_for(agent_a).first['push_message_body']).to include(secret)
    end
  end

  describe 'query count' do
    def build_hidden_notifications(count)
      Array.new(count) do
        hidden = create(:conversation, account: account, inbox: whatsapp_inbox, assignee: agent_b)
        create(:message, account: account, inbox: whatsapp_inbox, conversation: hidden, message_type: :incoming, content: secret)
        create(:notification, account: account, user: agent_a, primary_actor: hidden, notification_type: 'conversation_assignment')
      end
    end

    # Quantas vezes a checagem de papel roda numa pagina do sino. Em lote e uma
    # chamada por usuario e conta; por notificacao cresceria com o tamanho da pagina.
    def role_checks_for_index
      checks = 0
      %i[filter visible_members].each do |method_name|
        allow(Conversations::RoleVisibility).to receive(method_name).and_wrap_original do |original, *args, **kwargs|
          checks += 1
          original.call(*args, **kwargs)
        end
      end
      notifications_for(agent_a)
      checks
    end

    it 'checks the role once per page, not once per notification' do
      build_hidden_notifications(2)
      few = role_checks_for_index

      build_hidden_notifications(6)
      many = role_checks_for_index

      expect(few).to be >= 1
      expect(many).to eq(few)
    end
  end

  describe 'query cost' do
    let!(:other_inbox) { create(:inbox, account: account) }

    before { create(:inbox_member, user: agent_a, inbox: other_inbox) }

    def notification_on_other_channel
      other = create(:conversation, account: account, inbox: other_inbox, assignee: agent_b)
      create(:message, account: account, inbox: other_inbox, conversation: other, message_type: :incoming, content: 'oi')
      create(:notification, account: account, user: agent_a, primary_actor: other, notification_type: 'conversation_assignment')
    end

    def count_queries(&)
      count = 0
      counter = ->(_name, _started, _finished, _id, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA CACHE]) }
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
      count
    end

    # base: a mesma notificação com a checagem de papel neutralizada
    def base_and_checked(method_name)
      base = notification_on_other_channel
      checked = notification_on_other_channel
      allow(base).to receive(:content_hidden?).and_return(false)
      [base, checked].each { |notification| Notification.find(notification.id).public_send(method_name) } # aquece caches
      [count_queries { base.public_send(method_name) }, count_queries { checked.public_send(method_name) }]
    end

    it 'adds no query to push_event_data (the broadcast) on another channel' do
      base, checked = base_and_checked(:push_event_data)

      expect(checked).to eq(base)
    end

    it 'adds at most one light query to push_message_body on another channel (and none once the inbox is loaded)' do
      base, checked = base_and_checked(:push_message_body)

      expect(checked).to be <= base + 1
    end

    it 'does not look up the AccountUser again in the bell preload when the request already carries it' do
      hidden = create(:conversation, account: account, inbox: whatsapp_inbox, assignee: agent_b)
      create(:notification, account: account, user: agent_a, primary_actor: hidden, notification_type: 'conversation_assignment')
      Current.account_user = AccountUser.find_by(user: agent_a, account: account)
      notifications = agent_a.notifications.where(account_id: account.id)

      account_user_queries = 0
      counter = ->(_n, _s, _f, _i, payload) { account_user_queries += 1 if payload[:sql].include?('FROM "account_users"') }
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { Notification.preload_content_visibility(notifications) }

      expect(account_user_queries).to eq(0)
    ensure
      Current.account_user = nil
    end
  end
end
