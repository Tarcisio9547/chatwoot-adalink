# Adalink: #2083 - extraido do SearchService (que passou do limite de
# Metrics/ClassLength) para aplicar Conversations::RoleVisibility na busca
# de conversas e mensagens, restrito a caixas Channel::Whatsapp. Outras
# caixas e usuários sem papel restrito continuam sem mudança.
module SearchService::RoleVisibilityScoping
  private

  # Na caixa WhatsApp Cloud, a busca de conversas só devolve o que o papel do
  # usuário permite ver (mesma regra da lista de conversas). conversations_query
  # já vem restrito a accessable_inbox_ids, então RoleVisibility.filter só
  # refina mais o que o usuário já tinha acesso. Excluímos por id as
  # conversas WhatsApp que o papel NÃO deixa ver, em vez de reescrever o
  # filtro de inbox_id — assim compõe em AND com qualquer filtro adicional
  # (ex.: apply_inbox_id_filter) sem risco de sobrescrita.
  def apply_role_visibility_to_conversations(conversations_query)
    whatsapp_inbox_ids = current_account.inboxes.where(channel_type: 'Channel::Whatsapp').pluck(:id) & accessable_inbox_ids
    return conversations_query if whatsapp_inbox_ids.empty?

    whatsapp_scope = conversations_query.where(inbox_id: whatsapp_inbox_ids)
    return conversations_query if whatsapp_scope.none?

    hidden_ids = hidden_conversation_ids(whatsapp_scope)
    return conversations_query if hidden_ids.empty?

    conversations_query.where.not(id: hidden_ids)
  end

  # Mesma regra aplicada à busca de mensagens (GIN/LIKE) na caixa WhatsApp
  # Cloud — exclui por conversation_id as conversas que o papel não deixa
  # ver. should_skip_inbox_filtering? já decide se o usuário tem acesso a
  # todas as inboxes (admin ou dono de todas); só refinamos as inboxes
  # WhatsApp que o usuário realmente acessa.
  def apply_role_visibility_to_messages(messages_query)
    accessible_whatsapp_inbox_ids = current_account.inboxes.where(channel_type: 'Channel::Whatsapp').pluck(:id)
    accessible_whatsapp_inbox_ids &= accessable_inbox_ids unless should_skip_inbox_filtering?
    return messages_query if accessible_whatsapp_inbox_ids.empty?

    whatsapp_conversations = current_account.conversations.where(inbox_id: accessible_whatsapp_inbox_ids)
    return messages_query if whatsapp_conversations.none?

    hidden_ids = hidden_conversation_ids(whatsapp_conversations)
    return messages_query if hidden_ids.empty?

    messages_query.where.not(conversation_id: hidden_ids)
  end

  def hidden_conversation_ids(whatsapp_conversations)
    all_ids = whatsapp_conversations.pluck(:id)
    visible_ids = Conversations::RoleVisibility.filter(whatsapp_conversations, current_user, current_account).pluck(:id)
    all_ids - visible_ids
  end
end
