require 'rails_helper'

# Adalink: correção do juiz cego (#2083/#2084, decisão ALTA opção B) - o
# Chatwoot upstream (ParticipationListener) adiciona o novo responsável como
# participante mas nunca remove o anterior. Na caixa WhatsApp Cloud, isso faz
# o corretor que perdeu o lead continuar recebendo eventos ao vivo e achando
# a conversa na busca. Este listener remove SÓ o responsável anterior da
# lista de participantes quando a inbox é Channel::Whatsapp.
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
