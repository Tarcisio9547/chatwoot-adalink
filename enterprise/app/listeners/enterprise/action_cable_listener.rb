# Adalink: #2084 (escopo ampliado pelos comentários) — na caixa WhatsApp
# Cloud, os eventos ao vivo do ActionCable só vão para quem o papel permite
# ver a conversa (mesma regra de RoleVisibility usada pela busca em #2083 e
# pelo aviso persistido em NotificationListener). Outras caixas continuam
# broadcastando para todos os membros, igual ao comportamento upstream.
module Enterprise::ActionCableListener
  include Events::Types

  def copilot_message_created(event)
    copilot_message = event.data[:copilot_message]
    copilot_thread = copilot_message.copilot_thread
    account = copilot_thread.account
    user = copilot_thread.user

    broadcast(account, [user.pubsub_token], COPILOT_MESSAGE_CREATED, copilot_message.push_event_data)
  end

  def message_created(event)
    message, account = extract_message_and_account(event)
    conversation = message.conversation
    tokens = user_tokens(account, visible_members(conversation)) + contact_tokens(conversation.contact_inbox, message)

    broadcast(account, tokens, MESSAGE_CREATED, message.push_event_data)
  end

  def message_updated(event)
    message, account = extract_message_and_account(event)
    conversation = message.conversation
    tokens = user_tokens(account, visible_members(conversation)) + contact_tokens(conversation.contact_inbox, message)

    broadcast(account, tokens, MESSAGE_UPDATED, message.push_event_data.merge(previous_changes: event.data[:previous_changes]))
  end

  def first_reply_created(event)
    message, account = extract_message_and_account(event)
    conversation = message.conversation
    tokens = user_tokens(account, visible_members(conversation))

    broadcast(account, tokens, FIRST_REPLY_CREATED, message.push_event_data)
  end

  def conversation_created(event)
    conversation, account = extract_conversation_and_account(event)
    tokens = user_tokens(account, visible_members(conversation)) + contact_inbox_tokens(conversation.contact_inbox)

    broadcast(account, tokens, CONVERSATION_CREATED, conversation.push_event_data)
  end

  def conversation_read(event)
    conversation, account = extract_conversation_and_account(event)
    tokens = user_tokens(account, visible_members(conversation))

    broadcast(account, tokens, CONVERSATION_READ, conversation.push_event_data)
  end

  def conversation_status_changed(event)
    conversation, account = extract_conversation_and_account(event)
    tokens = user_tokens(account, visible_members(conversation)) + contact_inbox_tokens(conversation.contact_inbox)

    broadcast(account, tokens, CONVERSATION_STATUS_CHANGED, conversation.push_event_data)
  end

  def conversation_updated(event)
    conversation, account = extract_conversation_and_account(event)
    tokens = user_tokens(account, visible_members(conversation)) + contact_inbox_tokens(conversation.contact_inbox)

    broadcast(account, tokens, CONVERSATION_UPDATED, conversation.push_event_data)
  end

  def assignee_changed(event)
    conversation, account = extract_conversation_and_account(event)
    tokens = user_tokens(account, assignee_changed_recipients(conversation, event))

    broadcast(account, tokens, ASSIGNEE_CHANGED, conversation.push_event_data)
  end

  def team_changed(event)
    conversation, account = extract_conversation_and_account(event)
    tokens = user_tokens(account, visible_members(conversation))

    broadcast(account, tokens, TEAM_CHANGED, conversation.push_event_data)
  end

  def conversation_contact_changed(event)
    conversation, account = extract_conversation_and_account(event)
    tokens = user_tokens(account, visible_members(conversation))

    broadcast(account, tokens, CONVERSATION_CONTACT_CHANGED, conversation.push_event_data)
  end

  private

  # Membros da inbox que o papel permite ver esta conversa. Fora da caixa
  # WhatsApp, devolve todos os membros (comportamento atual, sem mudança).
  def visible_members(conversation)
    members = conversation.inbox.members
    return members unless conversation.inbox.whatsapp?

    Conversations::RoleVisibility.visible_members(conversation, members)
  end

  # Adalink: quem PERDE a conversa numa reatribuição também precisa do evento
  # assignee.changed, pra tela dele tirar a conversa da lista — mesmo que a
  # regra de papel não deixe mais ele ver a conversa depois da troca. Por
  # isso a lista de destino soma o assignee anterior (se ele ainda for membro
  # da inbox) aos destinatários calculados com o estado já atualizado.
  def assignee_changed_recipients(conversation, event)
    members = visible_members(conversation)
    return members unless conversation.inbox.whatsapp?

    previous_assignee = previous_assignee_for(conversation, event)
    return members if previous_assignee.blank?

    (members.to_a + [previous_assignee]).uniq
  end

  def previous_assignee_for(conversation, event)
    changed_attributes = event.data[:changed_attributes] || {}
    previous_assignee_id, = Array(changed_attributes['assignee_id'])
    return nil if previous_assignee_id.blank?

    conversation.inbox.members.find_by(id: previous_assignee_id)
  end
end
