# Adalink: #2084 (escopo ampliado pelos comentários) — na caixa WhatsApp
# Cloud, os eventos ao vivo do ActionCable só vão para quem o papel permite
# ver a conversa (mesma regra de RoleVisibility usada pela busca em #2083 e
# pelo aviso persistido em NotificationListener). Outras caixas continuam
# broadcastando para todos os membros, igual ao comportamento upstream —
# cada override chama `super` nesse caso, em vez de duplicar o método
# original inteiro.
module Enterprise::ActionCableListener
  include Events::Types
  include Enterprise::ActionCableListenerAssigneeChangeVisibility

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
    return super unless conversation.inbox.whatsapp?

    tokens = user_tokens(account, visible_members(conversation)) + contact_tokens(conversation.contact_inbox, message)
    broadcast(account, tokens, MESSAGE_CREATED, message.push_event_data)
  end

  def message_updated(event)
    message, account = extract_message_and_account(event)
    conversation = message.conversation
    return super unless conversation.inbox.whatsapp?

    tokens = user_tokens(account, visible_members(conversation)) + contact_tokens(conversation.contact_inbox, message)
    broadcast(account, tokens, MESSAGE_UPDATED, message.push_event_data.merge(previous_changes: event.data[:previous_changes]))
  end

  def first_reply_created(event)
    message, account = extract_message_and_account(event)
    conversation = message.conversation
    return super unless conversation.inbox.whatsapp?

    tokens = user_tokens(account, visible_members(conversation))
    broadcast(account, tokens, FIRST_REPLY_CREATED, message.push_event_data)
  end

  def conversation_created(event)
    conversation, account = extract_conversation_and_account(event)
    return super unless conversation.inbox.whatsapp?

    tokens = user_tokens(account, visible_members(conversation)) + contact_inbox_tokens(conversation.contact_inbox)
    broadcast(account, tokens, CONVERSATION_CREATED, conversation.push_event_data)
  end

  def conversation_read(event)
    conversation, account = extract_conversation_and_account(event)
    return super unless conversation.inbox.whatsapp?

    tokens = user_tokens(account, visible_members(conversation))
    broadcast(account, tokens, CONVERSATION_READ, conversation.push_event_data)
  end

  def conversation_status_changed(event)
    conversation, account = extract_conversation_and_account(event)
    return super unless conversation.inbox.whatsapp?

    tokens = user_tokens(account, visible_members(conversation)) + contact_inbox_tokens(conversation.contact_inbox)
    broadcast(account, tokens, CONVERSATION_STATUS_CHANGED, conversation.push_event_data)
  end

  def conversation_updated(event)
    conversation, account = extract_conversation_and_account(event)
    return super unless conversation.inbox.whatsapp?

    tokens = user_tokens(account, visible_members(conversation)) + contact_inbox_tokens(conversation.contact_inbox)
    broadcast(account, tokens, CONVERSATION_UPDATED, conversation.push_event_data)
  end

  def assignee_changed(event)
    conversation, account = extract_conversation_and_account(event)
    return super unless conversation.inbox.whatsapp?

    tokens = user_tokens(account, assignee_changed_recipients(conversation, event))
    broadcast(account, tokens, ASSIGNEE_CHANGED, conversation.push_event_data)
  end

  def team_changed(event)
    conversation, account = extract_conversation_and_account(event)
    return super unless conversation.inbox.whatsapp?

    tokens = user_tokens(account, visible_members(conversation))
    broadcast(account, tokens, TEAM_CHANGED, conversation.push_event_data)
  end

  def conversation_contact_changed(event)
    conversation, account = extract_conversation_and_account(event)
    return super unless conversation.inbox.whatsapp?

    tokens = user_tokens(account, visible_members(conversation))
    broadcast(account, tokens, CONVERSATION_CONTACT_CHANGED, conversation.push_event_data)
  end

  private

  # Membros da inbox que o papel permite ver esta conversa. Só é chamado
  # quando a caixa já é Channel::Whatsapp (ver `return super unless...` em
  # cada método público acima).
  def visible_members(conversation)
    Conversations::RoleVisibility.visible_members(conversation, conversation.inbox.members)
  end

  # Adalink: typing_on/typing_off usam este método privado da base, então
  # sobrescrevê-lo já corrige os dois eventos sem duplicar conversation_typing_on/off.
  def typing_event_listener_tokens(account, conversation, user)
    return super unless conversation.inbox.whatsapp?

    current_user_token = if user.is_a?(Contact)
                           conversation.contact_inbox.pubsub_token
                         elsif user.respond_to?(:pubsub_token)
                           user.pubsub_token
                         end

    tokens = user_tokens(account, visible_members(conversation)) + [conversation.contact_inbox.pubsub_token]
    current_user_token.present? ? tokens - [current_user_token] : tokens
  end
end
