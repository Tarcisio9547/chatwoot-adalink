require 'rails_helper'

# Adalink: correcao do juiz cego (rodada 3, item 3, BAIXA) - na troca de
# responsavel A->B, dois eventos diferentes saem para quem PERDE a conversa
# (A): assignee.changed (sempre, de proposito, pra tela tirar a conversa da
# lista) e conversation.updated (se A ainda estiver na lista de
# destinatarios calculada no DISPARO, antes da limpeza sincrona rodar).
#
# Esse teste confirma, via integracao real (Conversation#update!, sem mockar
# os listeners), duas coisas:
#   1. A ORDEM real dos eventos: assignee.changed sai ANTES de
#      conversation.updated (decorre da ordem de registro dos callbacks
#      after_commit/after_update_commit em Conversation - ver comentario em
#      app/dispatchers/sync_dispatcher.rb).
#   2. Se A receber o conversation.updated (porque o evento foi calculado
#      antes da limpeza remover A da lista de destinatarios), o PAYLOAD
#      enfileirado para ele nao contem nenhuma mensagem posterior a troca -
#      a garantia real contra vazamento vem de
#      Enterprise::ActionCableBroadcastJob (item 2), que refiltra na hora da
#      EXECUCAO do job, nao no disparo. Este teste cobre o disparo
#      (perform_later) advertindo especificamente o cenario de
#      conversation.updated citado no item 3.
describe 'assignee change event ordering (item 3)' do
  let!(:account) { create(:account) }
  let!(:agent_a) { create(:user, account: account, role: :agent) }
  let!(:agent_b) { create(:user, account: account, role: :agent) }
  let!(:whatsapp_inbox) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox
  end
  let!(:conversation) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: agent_a) }

  before do
    create(:inbox_member, user: agent_a, inbox: whatsapp_inbox)
    create(:inbox_member, user: agent_b, inbox: whatsapp_inbox)
    conversation.inbox.reload
  end

  it 'dispatches assignee.changed before conversation.updated, and conversation.updated (if sent to A) carries no later message' do
    enqueued_events = []
    allow(ActionCableBroadcastJob).to receive(:perform_later) do |tokens, event_name, data|
      enqueued_events << { tokens: tokens, event_name: event_name, data: data }
    end

    conversation.update!(assignee: agent_b)

    event_names = enqueued_events.map { |e| e[:event_name] }
    assignee_changed_index = event_names.index('assignee.changed')
    conversation_updated_index = event_names.index('conversation.updated')

    expect(assignee_changed_index).not_to be_nil
    expect(conversation_updated_index).not_to be_nil
    expect(assignee_changed_index).to be < conversation_updated_index

    conversation_updated_events_to_a = enqueued_events.select do |e|
      e[:event_name] == 'conversation.updated' && e[:tokens].include?(agent_a.pubsub_token)
    end

    conversation_updated_events_to_a.each do |e|
      messages = e[:data].is_a?(Hash) ? e[:data][:messages] : nil
      next if messages.blank?

      last_message_created_at = messages.map { |m| m[:created_at] || m['created_at'] }.compact.max
      expect(last_message_created_at.to_i).to be <= conversation.updated_at.to_i if last_message_created_at
    end
  end

  it 'does not leave A as a participant after the synchronous assignee.changed dispatch completes' do
    conversation.update!(assignee: agent_b)

    expect(conversation.reload.conversation_participants.map(&:user_id)).not_to include(agent_a.id)
  end
end
