require 'rails_helper'

# O job assíncrono do ParticipationListener pode rodar DEPOIS de a conversa já ter
# trocado A->B (e a limpeza ter removido A). O listener tem que ler o responsável do
# banco, não confiar no valor do evento no enqueue. Vale em TODOS os canais: senão o
# ex-responsável voltaria a ser participante (e, com visão restrita, veria a conversa).
describe ParticipationListener do
  let(:listener) { described_class.instance }
  let!(:account) { create(:account) }
  let!(:agent_a) { create(:user, account: account, role: :agent) }
  let!(:agent_b) { create(:user, account: account, role: :agent) }

  describe '#assignee_changed' do
    context 'when the inbox is Channel::Whatsapp' do
      let!(:whatsapp_inbox) do
        create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox
      end
      let!(:conversation) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: nil) }

      before do
        create(:inbox_member, user: agent_a, inbox: whatsapp_inbox)
        create(:inbox_member, user: agent_b, inbox: whatsapp_inbox)
      end

      it 'does not bring the stale assignee back when the DB already moved on (race with the async job)' do
        # Simulates the real race: the conversation object was LOADED (and the
        # EventDispatcherJob payload serialized) BEFORE the reassignment to B -
        # a separate Ruby object, like a job deserializing its own copy.
        conversation.update!(assignee: agent_a)
        stale_conversation = Conversation.find(conversation.id)
        event = Events::Base.new(:assignee_changed, Time.zone.now, conversation: stale_conversation)

        # The DB has already moved on to B by the time the listener runs (e.g.
        # the cleanup listener already ran for the A->B transition).
        conversation.update!(assignee: agent_b)

        listener.assignee_changed(event)

        participant_ids = conversation.reload.conversation_participants.map(&:user_id)
        expect(participant_ids).not_to include(agent_a.id)
        expect(participant_ids).to include(agent_b.id)
      end

      it 'does not insert anyone when the DB has since moved to unassigned' do
        conversation.update!(assignee: agent_a)
        stale_conversation = Conversation.find(conversation.id)
        event = Events::Base.new(:assignee_changed, Time.zone.now, conversation: stale_conversation)

        conversation.update!(assignee: nil)

        listener.assignee_changed(event)

        expect(conversation.reload.conversation_participants.map(&:user_id)).not_to include(agent_a.id)
      end

      it 'does not alter the conversation object carried by the event' do
        conversation.update!(assignee: agent_a)
        event = Events::Base.new(:assignee_changed, Time.zone.now, conversation: conversation)

        listener.assignee_changed(event)

        expect(conversation.saved_change_to_assignee_id?).to be true
      end

      it 'still adds the assignee normally when there is no race (DB matches the event)' do
        conversation.update!(assignee: agent_a)
        event = Events::Base.new(:assignee_changed, Time.zone.now, conversation: conversation)

        listener.assignee_changed(event)

        expect(conversation.conversation_participants.map(&:user_id)).to include(agent_a.id)
      end
    end

    context 'when the inbox is not Channel::Whatsapp (web widget, e-mail, API...)' do
      let!(:inbox) { create(:inbox, account: account) }
      let!(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: nil) }

      before do
        create(:inbox_member, user: agent_a, inbox: inbox)
        create(:inbox_member, user: agent_b, inbox: inbox)
      end

      it 'does not bring the stale assignee back when the DB already moved on (same guarantee as WhatsApp)' do
        conversation.update!(assignee: agent_a)
        stale_conversation = Conversation.find(conversation.id)
        event = Events::Base.new(:assignee_changed, Time.zone.now, conversation: stale_conversation)

        conversation.update!(assignee: agent_b)

        listener.assignee_changed(event)

        participant_ids = conversation.reload.conversation_participants.map(&:user_id)
        expect(participant_ids).not_to include(agent_a.id)
        expect(participant_ids).to include(agent_b.id)
      end

      it 'still adds the assignee normally when there is no race' do
        conversation.update!(assignee: agent_a)
        event = Events::Base.new(:assignee_changed, Time.zone.now, conversation: conversation)

        listener.assignee_changed(event)

        expect(conversation.conversation_participants.map(&:user_id)).to include(agent_a.id)
      end
    end
  end
end
