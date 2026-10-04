require 'rails_helper'

# O ParticipationListener upstream adiciona o novo responsável como participante
# mas nunca remove o anterior. Isso deixaria quem perdeu a conversa recebendo eventos
# ao vivo, achando a conversa na busca e, com visão restrita, vendo-a na lista para
# sempre. Este listener remove SÓ o responsável anterior da lista de participantes,
# em TODOS os canais (WhatsApp, e-mail, site...). Quem foi adicionado manualmente fica.
describe ParticipationCleanupListener do
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

      # O responsável é relido sob lock: um evento atrasado de A->B não pode remover A
      # se a conversa já voltou pra A.
      it 'keeps the participant when the previous assignee is the current assignee again' do
        changed_attributes = { 'assignee_id' => [agent_a.id, agent_b.id] }
        event = Events::Base.new(:assignee_changed, Time.zone.now, conversation: conversation, changed_attributes: changed_attributes)

        listener.assignee_changed(event)

        expect(conversation.reload.assignee_id).to eq(agent_a.id)
        expect(conversation.conversation_participants.map(&:user_id)).to include(agent_a.id)
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

    context 'when the inbox is not Channel::Whatsapp (web widget, e-mail, API...)' do
      let!(:inbox) { create(:inbox, account: account) }
      let!(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: agent_a) }

      before do
        # Sem os listeners reais do update!: o spec chama o listener direto.
        allow(Rails.configuration.dispatcher).to receive(:dispatch)
        create(:inbox_member, user: agent_a, inbox: inbox)
        create(:inbox_member, user: agent_b, inbox: inbox)
        conversation.conversation_participants.create!(user: agent_a)
        conversation.conversation_participants.create!(user: manual_participant)
      end

      def reassign_event(from:, to:)
        conversation.update!(assignee: to)
        Events::Base.new(:assignee_changed, Time.zone.now, conversation: conversation,
                                                           changed_attributes: { 'assignee_id' => [from.id, to.id] })
      end

      it 'removes the previous assignee from the participants' do
        listener.assignee_changed(reassign_event(from: agent_a, to: agent_b))

        expect(conversation.conversation_participants.map(&:user_id)).not_to include(agent_a.id)
      end

      it 'keeps a manually added participant' do
        listener.assignee_changed(reassign_event(from: agent_a, to: agent_b))

        expect(conversation.conversation_participants.map(&:user_id)).to include(manual_participant.id)
      end

      it 'does nothing on the first assignment (no previous assignee) and runs no query' do
        event = Events::Base.new(:assignee_changed, Time.zone.now, conversation: conversation,
                                                                   changed_attributes: { 'assignee_id' => [nil, agent_b.id] })
        queries = 0
        counter = ->(_name, _started, _finished, _id, payload) { queries += 1 unless payload[:name].in?(%w[SCHEMA CACHE]) }

        ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { listener.assignee_changed(event) }

        expect(queries).to eq(0)
        expect(conversation.conversation_participants.map(&:user_id)).to include(agent_a.id)
      end

      it 'keeps the participant when the previous assignee is the current assignee again (late event)' do
        event = Events::Base.new(:assignee_changed, Time.zone.now, conversation: conversation,
                                                                   changed_attributes: { 'assignee_id' => [agent_a.id, agent_b.id] })

        listener.assignee_changed(event)

        expect(conversation.reload.assignee_id).to eq(agent_a.id)
        expect(conversation.conversation_participants.map(&:user_id)).to include(agent_a.id)
      end

      # O CRM adiciona o gestor do corretor como participante de uma conversa do WhatsApp Pessoal
      # (caixa Channel::Api). Ele não é membro nem responsável: o acesso vem SÓ da participação.
      # A limpeza remove apenas o responsável anterior, então o gestor nunca sai.
      it 'never removes a manager who is only a participant (not a member, not the assignee) when the conversation changes hands' do
        manager = create(:user, account: account, role: :agent)
        conversation.conversation_participants.create!(user: manager)

        listener.assignee_changed(reassign_event(from: agent_a, to: agent_b))

        expect(conversation.conversation_participants.map(&:user_id)).to include(manager.id)
        expect(conversation.conversation_participants.map(&:user_id)).not_to include(agent_a.id)
      end

      it 'removes a previous assignee that has a restricted role (the access it would otherwise keep forever)' do
        role = create(:custom_role, account: account, permissions: %w[conversation_unassigned_manage])
        AccountUser.find_by(user: agent_a, account: account).update!(role: :agent, custom_role: role)

        listener.assignee_changed(reassign_event(from: agent_a, to: agent_b))

        expect(Conversations::RoleVisibility.visible_members(conversation, [agent_a])).to be_empty
      end
    end
  end
end
