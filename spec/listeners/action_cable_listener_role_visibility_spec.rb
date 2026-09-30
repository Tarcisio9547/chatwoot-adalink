require 'rails_helper'

# Adalink: #2084 (escopo ampliado pelos comentarios) - na caixa WhatsApp
# Cloud, os eventos ao vivo do ActionCable so vao para quem o papel permite
# ver a conversa. Outras caixas continuam broadcastando para todos os
# membros, igual ao comportamento anterior. Arquivo separado de
# action_cable_listener_spec.rb para nao herdar memoized helpers do describe
# principal (admin, inbox, conversation) que nao sao usados aqui.
describe ActionCableListener do
  let(:listener) { described_class.instance }
  let!(:account) { create(:account) }
  let!(:agent) { create(:user, account: account, role: :agent) }
  let!(:whatsapp_inbox) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox
  end
  let!(:setor_role) { create(:custom_role, account: account, permissions: %w[conversation_participating_manage]) }
  let!(:all_role) { create(:custom_role, account: account, permissions: %w[conversation_manage]) }
  let!(:setor_member) { create(:user, account: account, role: :agent) }
  let!(:all_member) { create(:user, account: account, role: :agent) }
  let!(:whatsapp_conversation) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: agent) }

  before do
    Current.user = nil
    Current.account = nil

    create(:inbox_member, user: setor_member, inbox: whatsapp_inbox)
    create(:inbox_member, user: all_member, inbox: whatsapp_inbox)
    create(:inbox_member, user: agent, inbox: whatsapp_inbox)

    AccountUser.find_by(user: setor_member, account: account).update(custom_role: setor_role)
    AccountUser.find_by(user: all_member, account: account).update(custom_role: all_role)

    # HACK: to reload conversation inbox members (mesmo padrao do
    # action_cable_listener_spec.rb original) - os membros sao adicionados
    # acima, depois da conversa ja ter carregado a associacao inbox.
    whatsapp_conversation.inbox.reload
  end

  describe '#conversation_created' do
    let(:event_name) { :'conversation.created' }
    let!(:event) { Events::Base.new(event_name, Time.zone.now, conversation: whatsapp_conversation) }

    it 'does not send the event to a member with the Setor role' do
      expect(ActionCableBroadcastJob).to receive(:perform_later) do |tokens, *_args|
        expect(tokens).not_to include(setor_member.pubsub_token)
      end
      listener.conversation_created(event)
    end

    it 'sends the event to a member with the "all conversations" role' do
      expect(ActionCableBroadcastJob).to receive(:perform_later) do |tokens, *_args|
        expect(tokens).to include(all_member.pubsub_token)
      end
      listener.conversation_created(event)
    end

    it 'sends the event to the assignee' do
      expect(ActionCableBroadcastJob).to receive(:perform_later) do |tokens, *_args|
        expect(tokens).to include(agent.pubsub_token)
      end
      listener.conversation_created(event)
    end
  end

  describe '#message_created' do
    let(:event_name) { :'message.created' }
    let!(:whatsapp_message) do
      create(:message, message_type: 'outgoing', account: account, inbox: whatsapp_inbox, conversation: whatsapp_conversation)
    end
    let!(:event) { Events::Base.new(event_name, Time.zone.now, message: whatsapp_message) }

    it 'does not send the event to a member with the Setor role' do
      expect(ActionCableBroadcastJob).to receive(:perform_later) do |tokens, *_args|
        expect(tokens).not_to include(setor_member.pubsub_token)
      end
      listener.message_created(event)
    end
  end

  describe '#assignee_changed' do
    let(:event_name) { :'conversation.assignee_changed' }

    it 'sends the event to whoever LOSES the conversation, even without continued visibility' do
      # Setor member currently sees nothing (not assigned, not participant). Reassign FROM
      # setor_member TO agent, and confirm setor_member still gets notified so their UI can
      # drop the conversation from the list.
      conversation = create(:conversation, account: account, inbox: whatsapp_inbox, assignee: setor_member)
      conversation.inbox.reload
      conversation.update!(assignee: agent)
      changed_attributes = { 'assignee_id' => [setor_member.id, agent.id] }
      event = Events::Base.new(event_name, Time.zone.now, conversation: conversation, changed_attributes: changed_attributes)

      expect(ActionCableBroadcastJob).to receive(:perform_later) do |tokens, *_args|
        expect(tokens).to include(setor_member.pubsub_token)
        expect(tokens).to include(agent.pubsub_token)
      end
      listener.assignee_changed(event)
    end
  end

  context 'when the inbox is not Channel::Whatsapp' do
    let!(:other_inbox) { create(:inbox, account: account) }
    let!(:other_inbox_conversation) { create(:conversation, account: account, inbox: other_inbox, assignee: agent) }

    before do
      create(:inbox_member, user: setor_member, inbox: other_inbox)
      other_inbox_conversation.inbox.reload
    end

    it 'keeps sending the event to every inbox member, role or not (current behaviour, unchanged)' do
      event = Events::Base.new(:'conversation.created', Time.zone.now, conversation: other_inbox_conversation)

      expect(ActionCableBroadcastJob).to receive(:perform_later) do |tokens, *_args|
        expect(tokens).to include(setor_member.pubsub_token)
      end
      listener.conversation_created(event)
    end
  end
end
