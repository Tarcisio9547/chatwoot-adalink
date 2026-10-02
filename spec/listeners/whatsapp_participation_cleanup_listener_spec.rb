require 'rails_helper'

# O ParticipationListener upstream adiciona o novo responsável como participante
# mas nunca remove o anterior. Na caixa WhatsApp isso deixaria quem perdeu o lead
# recebendo eventos ao vivo e achando a conversa na busca. Este listener remove SÓ
# o responsável anterior da lista de participantes quando a inbox é
# Channel::Whatsapp.
describe WhatsappParticipationCleanupListener do
  let(:listener) { described_class.instance }
  let!(:account) { create(:account) }
  let!(:agent_a) { create(:user, account: account, role: :agent) }
  let!(:agent_b) { create(:user, account: account, role: :agent) }
  let!(:manual_participant) { create(:user, account: account, role: :agent) }

  describe '#assignee_changed' do
    context 'when the inbox is Channel::Whatsapp' do
      let!(:whatsapp_inbox) do
        create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox
      end
      let!(:conversation) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: agent_a) }

      before do
        create(:inbox_member, user: agent_a, inbox: whatsapp_inbox)
        create(:inbox_member, user: agent_b, inbox: whatsapp_inbox)
        create(:inbox_member, user: manual_participant, inbox: whatsapp_inbox)
        conversation.conversation_participants.create!(user: agent_a)
        conversation.conversation_participants.create!(user: manual_participant)
      end

      it 'removes the previous assignee from participants when the conversation is reassigned' do
        conversation.update!(assignee: agent_b)
        changed_attributes = { 'assignee_id' => [agent_a.id, agent_b.id] }
        event = Events::Base.new(:assignee_changed, Time.zone.now, conversation: conversation, changed_attributes: changed_attributes)

        listener.assignee_changed(event)

        expect(conversation.conversation_participants.map(&:user_id)).not_to include(agent_a.id)
      end

      it 'keeps a manually added participant' do
        conversation.update!(assignee: agent_b)
        changed_attributes = { 'assignee_id' => [agent_a.id, agent_b.id] }
        event = Events::Base.new(:assignee_changed, Time.zone.now, conversation: conversation, changed_attributes: changed_attributes)

        listener.assignee_changed(event)

        expect(conversation.conversation_participants.map(&:user_id)).to include(manual_participant.id)
      end

      it 'does nothing when there is no previous assignee' do
        conversation.update!(assignee: agent_b)
        changed_attributes = { 'assignee_id' => [nil, agent_b.id] }
        event = Events::Base.new(:assignee_changed, Time.zone.now, conversation: conversation, changed_attributes: changed_attributes)

        expect { listener.assignee_changed(event) }.not_to raise_error
      end

      # Este listener roda dentro do after_commit do model, antes dos callbacks
      # que ainda leem saved_changes (ex.: AssignmentHandler#notify_assignment_change
      # avalia saved_change_to_team_id? depois do assignee.changed). Recarregar o
      # objeto do evento apagaria esses saved_changes.
      it 'does not alter the conversation object carried by the event' do
        conversation.update!(assignee: agent_b)
        changed_attributes = { 'assignee_id' => [agent_a.id, agent_b.id] }
        event = Events::Base.new(:assignee_changed, Time.zone.now, conversation: conversation, changed_attributes: changed_attributes)

        listener.assignee_changed(event)

        expect(conversation.saved_change_to_assignee_id?).to be true
      end

      # A limpeza vale também pra administrador e agente sem custom_role: os dois
      # seguem vendo toda conversa da caixa pela visão "Todas"
      # (Conversations::RoleVisibility.unrestricted?), sem depender de ser participante
      # ou assignee.
      context 'when the previous assignee is an administrator' do
        let!(:admin) { create(:user, account: account, role: :administrator) }
        let!(:admin_conversation) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: admin) }

        before do
          create(:inbox_member, user: admin, inbox: whatsapp_inbox)
          admin_conversation.conversation_participants.create!(user: admin)
        end

        it 'removes the administrator from participants after reassignment' do
          admin_conversation.update!(assignee: agent_b)
          changed_attributes = { 'assignee_id' => [admin.id, agent_b.id] }
          event = Events::Base.new(:assignee_changed, Time.zone.now, conversation: admin_conversation, changed_attributes: changed_attributes)

          listener.assignee_changed(event)

          expect(admin_conversation.conversation_participants.map(&:user_id)).not_to include(admin.id)
        end

        it 'still shows the conversation to the administrator via RoleVisibility (the "Todas" view)' do
          admin_conversation.update!(assignee: agent_b)
          changed_attributes = { 'assignee_id' => [admin.id, agent_b.id] }
          event = Events::Base.new(:assignee_changed, Time.zone.now, conversation: admin_conversation, changed_attributes: changed_attributes)

          listener.assignee_changed(event)

          visible = Conversations::RoleVisibility.visible_members(admin_conversation, [admin])
          expect(visible).to include(admin)
        end
      end
    end

    context 'when the inbox is not Channel::Whatsapp' do
      let!(:inbox) { create(:inbox, account: account) }
      let!(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: agent_a) }

      before do
        create(:inbox_member, user: agent_a, inbox: inbox)
        create(:inbox_member, user: agent_b, inbox: inbox)
        conversation.conversation_participants.create!(user: agent_a)
      end

      it 'keeps the previous assignee as a participant (current behaviour, unchanged)' do
        conversation.update!(assignee: agent_b)
        changed_attributes = { 'assignee_id' => [agent_a.id, agent_b.id] }
        event = Events::Base.new(:assignee_changed, Time.zone.now, conversation: conversation, changed_attributes: changed_attributes)

        listener.assignee_changed(event)

        expect(conversation.conversation_participants.map(&:user_id)).to include(agent_a.id)
      end
    end
  end
end
