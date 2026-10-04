# Adalink: participante adicionado ou removido (conversation.participants_changed). Quem entrou
# passa a ver a conversa na lista; quem saiu recebe o payload sem mensagens (a tela tira a conversa
# pelo participant_ids novo). Os destinatários seguem a mesma regra dos demais eventos de
# conversa: membros da caixa + participantes + administradores, filtrados por papel no WhatsApp
# (around_member_filtering). Separado do Enterprise::ActionCableListener pra não estourar o
# limite de Metrics/ModuleLength.
module Enterprise::ActionCableListenerParticipants
  include Events::Types

  def conversation_participants_changed(event)
    around_member_filtering(event.data[:conversation]) do
      conversation, account = extract_conversation_and_account(event)
      payload = conversation.agent_push_event_data
      tokens = user_tokens(account, conversation_agents(conversation))
      removed_tokens = User.where(id: event.data[:removed_user_ids]).pluck(:pubsub_token) - tokens

      broadcast(account, tokens, CONVERSATION_PARTICIPANTS_CHANGED, payload)
      broadcast(account, removed_tokens, CONVERSATION_PARTICIPANTS_CHANGED, payload.except(:messages))
    end
  end
end
