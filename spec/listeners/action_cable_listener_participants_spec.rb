require 'rails_helper'

# Participante que não é membro da caixa também recebe os eventos ao vivo da conversa
# (mensagem nova, atualização, troca de responsável, adição/remoção de participante), sem
# duplicar token e sem consulta por participante. O payload com participant_ids só vai aos
# agentes: o contato (widget) e os webhooks externos nunca o recebem.
# rubocop:disable RSpec/DescribeMethod, RSpec/SpecFilePathFormat -- cobre vários eventos do listener.
describe ActionCableListener, 'participants as recipients' do
  let(:listener) { described_class.instance }
  let!(:account) { create(:account) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:member) { create(:user, account: account, role: :agent) }
  let!(:outsider) { create(:user, account: account, role: :agent) }
  let!(:bystander) { create(:user, account: account, role: :agent) }
  let!(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: member) }
  let(:contact_token) { conversation.contact_inbox.pubsub_token }
  let(:sent) { [] }

  before do
    create(:inbox_member, inbox: inbox, user: member)
    create(:conversation_participant, conversation: conversation, account: account, user: outsider)
    Current.user = nil
    Current.account = nil
    allow(ActionCableBroadcastJob).to receive(:perform_later) { |tokens, name, data| sent << { tokens: tokens, name: name, data: data } }
  end

  def event_for(name, **data)
    Events::Base.new(name, Time.zone.now, **data)
  end

  def tokens_of(name)
    sent.select { |entry| entry[:name] == name }.flat_map { |entry| entry[:tokens] }
  end

  def message
    @message ||= create(:message, message_type: 'outgoing', account: account, inbox: inbox, conversation: conversation)
  end

  # [método do listener, nome do evento, argumentos do evento]
  def events
    {
      message_created: ['message.created', { message: message }],
      message_updated: ['message.updated', { message: message, previous_changes: {} }],
      first_reply_created: ['first.reply.created', { message: message }],
      conversation_created: ['conversation.created', { conversation: conversation }],
      conversation_read: ['conversation.read', { conversation: conversation }],
      conversation_status_changed: ['conversation.status_changed', { conversation: conversation }],
      conversation_updated: ['conversation.updated', { conversation: conversation }],
      assignee_changed: ['assignee.changed', { conversation: conversation }],
      team_changed: ['team.changed', { conversation: conversation }],
      conversation_contact_changed: ['conversation.contact_changed', { conversation: conversation }]
    }
  end

  %i[message_created message_updated first_reply_created conversation_created conversation_read conversation_status_changed
     conversation_updated assignee_changed team_changed conversation_contact_changed].each do |method_name|
    describe "##{method_name}" do
      def fire(method_name)
        event_name, data = events.fetch(method_name)
        sent.clear # criar a mensagem/conversa do cenário já disparou eventos reais
        listener.public_send(method_name, event_for(event_name, **data))
        event_name
      end

      it 'reaches a participant who is not a member of the inbox, plus members and admins' do
        name = fire(method_name)

        expect(tokens_of(name)).to include(outsider.pubsub_token, member.pubsub_token, admin.pubsub_token)
      end

      it 'does not reach an agent who is neither member nor participant' do
        name = fire(method_name)

        expect(tokens_of(name)).not_to include(bystander.pubsub_token)
      end

      it 'does not repeat the token of a participant who is also a member' do
        create(:conversation_participant, conversation: conversation, account: account, user: member)

        name = fire(method_name)

        tokens = tokens_of(name)
        expect(tokens.tally.values.max).to eq(1)
        expect(tokens).to include(member.pubsub_token)
      end
    end
  end

  describe 'typing events' do
    it 'reach a participant who is not a member (and never carry participant_ids)' do
      listener.conversation_typing_on(event_for('conversation.typing_on', conversation: conversation, user: member, is_private: false))

      entry = sent.find { |item| item[:name] == 'conversation.typing_on' }
      expect(entry[:tokens]).to include(outsider.pubsub_token, admin.pubsub_token, contact_token)
      expect(entry[:data][:conversation]).not_to have_key(:participant_ids)
    end
  end

  describe 'participant_ids in the payload sent to the broadcast job' do
    %i[conversation_created conversation_read conversation_status_changed conversation_updated assignee_changed team_changed
       conversation_contact_changed].each do |method_name|
      it "is included in ##{method_name} (agent audience; the job strips it for the contact)" do
        event_name, data = events.fetch(method_name)
        sent.clear
        listener.public_send(method_name, event_for(event_name, **data))

        payload = sent.find { |entry| entry[:name] == event_name }[:data]
        expect(payload[:participant_ids]).to contain_exactly(outsider.id)
      end
    end

    it 'is not added to message events (their payload has no conversation snapshot)' do
      event = event_for('message.created', message: message)
      sent.clear
      listener.message_created(event)

      expect(sent.find { |entry| entry[:name] == 'message.created' }[:data]).not_to have_key(:participant_ids)
    end
  end

  describe 'query cost' do
    def count_queries(&)
      count = 0
      counter = ->(_name, _started, _finished, _id, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA CACHE]) }
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
      count
    end

    it 'does not grow with the number of participants (no N+1)' do
      event = event_for('conversation.updated', conversation: conversation)
      listener.conversation_updated(event)
      few = count_queries { listener.conversation_updated(event) }

      5.times { create(:conversation_participant, conversation: conversation, account: account, user: create(:user, account: account)) }
      many = count_queries { listener.conversation_updated(event) }

      expect(many).to eq(few)
    end
  end

  describe '#conversation_participants_changed' do
    let(:removed) { create(:user, account: account, role: :agent) }
    let(:event) do
      event_for('conversation.participants_changed', conversation: conversation, added_user_ids: [outsider.id], removed_user_ids: [removed.id])
    end

    it 'reaches the current participants, members and admins, and the user who was removed' do
      listener.conversation_participants_changed(event)

      expect(tokens_of('conversation.participants_changed')).to include(
        outsider.pubsub_token, member.pubsub_token, admin.pubsub_token, removed.pubsub_token
      )
    end

    it 'carries the fresh participant_ids' do
      listener.conversation_participants_changed(event)

      payloads = sent.select { |entry| entry[:name] == 'conversation.participants_changed' }.pluck(:data)
      expect(payloads).to all(include(participant_ids: [outsider.id]))
    end

    it 'sends the removed user a payload without messages (he lost the access)' do
      create(:message, message_type: 'incoming', account: account, inbox: inbox, conversation: conversation, content: 'segredo')

      listener.conversation_participants_changed(event)

      removed_entry = sent.find { |entry| entry[:tokens] == [removed.pubsub_token] }
      expect(removed_entry[:data][:messages]).to be_blank
      expect(removed_entry[:data].to_json).not_to include('segredo')
    end

    it 'does not reach the contact (widget)' do
      listener.conversation_participants_changed(event)

      expect(tokens_of('conversation.participants_changed')).not_to include(contact_token)
    end

    it 'does not reach someone who is neither member nor participant' do
      listener.conversation_participants_changed(event)

      expect(tokens_of('conversation.participants_changed')).not_to include(bystander.pubsub_token)
    end

    it 'does not send the removed user a second copy when he is still a member' do
      create(:inbox_member, inbox: inbox, user: removed)

      listener.conversation_participants_changed(event)

      expect(tokens_of('conversation.participants_changed').tally[removed.pubsub_token]).to eq(1)
    end
  end

  describe 'WhatsApp inbox (role visibility)' do
    let!(:whatsapp_inbox) do
      create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox
    end
    let!(:whatsapp_conversation) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: member) }
    let!(:restricted_member) { create(:user, account: account, role: :agent) }

    before do
      [member, restricted_member].each { |user| create(:inbox_member, inbox: whatsapp_inbox, user: user) }
      role = create(:custom_role, account: account, permissions: %w[conversation_participating_manage])
      AccountUser.find_by(user: restricted_member, account: account).update!(role: :agent, custom_role: role)
      create(:conversation_participant, conversation: whatsapp_conversation, account: account, user: outsider)
    end

    it 'reaches the participant outside the inbox and hides the conversation from a restricted member who is not a participant' do
      listener.conversation_updated(event_for('conversation.updated', conversation: whatsapp_conversation))

      tokens = tokens_of('conversation.updated')
      expect(tokens).to include(outsider.pubsub_token, member.pubsub_token)
      expect(tokens).not_to include(restricted_member.pubsub_token)
    end

    it 'reaches a restricted participant' do
      create(:conversation_participant, conversation: whatsapp_conversation, account: account, user: restricted_member)

      listener.conversation_updated(event_for('conversation.updated', conversation: whatsapp_conversation))

      expect(tokens_of('conversation.updated')).to include(restricted_member.pubsub_token)
    end
  end
end
# rubocop:enable RSpec/DescribeMethod, RSpec/SpecFilePathFormat
