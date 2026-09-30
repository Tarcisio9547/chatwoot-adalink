# Adalink: #2083 - extraido do SearchService (que passou do limite de
# Metrics/ClassLength) para aplicar Conversations::RoleVisibility na busca
# de conversas e mensagens, restrito a caixas Channel::Whatsapp. Outras
# caixas e usuários sem papel restrito continuam sem mudança.
#
# Performance: sai cedo (nenhuma query extra) para admin e agente sem papel
# restrito via RoleVisibility.unrestricted?, e usa subconsulta SQL (relation,
# não array plucado em memória) para excluir as conversas ocultas.
module SearchService::RoleVisibilityScoping
  private

  # Na caixa WhatsApp Cloud, a busca de conversas só devolve o que o papel do
  # usuário permite ver (mesma regra da lista de conversas). conversations_query
  # já vem restrito a accessable_inbox_ids, então RoleVisibility.filter só
  # refina mais o que o usuário já tinha acesso. Excluímos por id (subquery)
  # as conversas WhatsApp que o papel NÃO deixa ver, em vez de reescrever o
  # filtro de inbox_id — assim compõe em AND com qualquer filtro adicional
  # (ex.: apply_inbox_id_filter) sem risco de sobrescrita.
  def apply_role_visibility_to_conversations(conversations_query)
    return conversations_query if Conversations::RoleVisibility.unrestricted?(current_user, current_account.id, account_user: account_user)

    whatsapp_inbox_ids = current_account.inboxes.where(channel_type: 'Channel::Whatsapp').pluck(:id) & accessable_inbox_ids
    return conversations_query if whatsapp_inbox_ids.empty?

    whatsapp_scope = conversations_query.where(inbox_id: whatsapp_inbox_ids)
    hidden_ids_subquery = hidden_conversation_ids_subquery(whatsapp_scope)

    conversations_query.where.not(id: hidden_ids_subquery)
  end

  # Mesma regra aplicada à busca de mensagens (GIN/LIKE) na caixa WhatsApp
  # Cloud — exclui por conversation_id (subquery) as conversas que o papel
  # não deixa ver. should_skip_inbox_filtering? já decide se o usuário tem
  # acesso a todas as inboxes (admin ou dono de todas); só refinamos as
  # inboxes WhatsApp que o usuário realmente acessa.
  def apply_role_visibility_to_messages(messages_query)
    return messages_query if Conversations::RoleVisibility.unrestricted?(current_user, current_account.id, account_user: account_user)

    accessible_whatsapp_inbox_ids = current_account.inboxes.where(channel_type: 'Channel::Whatsapp').pluck(:id)
    accessible_whatsapp_inbox_ids &= accessable_inbox_ids unless should_skip_inbox_filtering?
    return messages_query if accessible_whatsapp_inbox_ids.empty?

    whatsapp_conversations = current_account.conversations.where(inbox_id: accessible_whatsapp_inbox_ids)
    hidden_ids_subquery = hidden_conversation_ids_subquery(whatsapp_conversations)

    messages_query.where.not(conversation_id: hidden_ids_subquery)
  end

  # Subconsulta SQL (WHERE id NOT IN (SELECT id FROM conversations WHERE ...
  # AND id NOT IN (visible_ids_subquery))): não força a execução em memória,
  # o Postgres resolve tudo numa query só.
  def hidden_conversation_ids_subquery(whatsapp_conversations)
    visible_scope = Conversations::RoleVisibility.filter(whatsapp_conversations, current_user, current_account)
    whatsapp_conversations.where.not(id: visible_scope).select(:id)
  end
end
