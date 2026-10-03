# Aplica Conversations::RoleVisibility na busca de conversas e mensagens, só em
# caixas Channel::Whatsapp. Outras caixas e usuários sem papel restrito (admin,
# agente sem custom_role) saem cedo, sem nenhuma consulta extra. As caixas
# WhatsApp vêm do mesmo pluck de accessable_inbox_ids (id + channel_type), então
# nem a conta sem caixa WhatsApp paga consulta.
module SearchService::RoleVisibilityScoping
  private

  # Na caixa WhatsApp a busca de conversas só devolve o que o papel do usuário
  # permite ver (mesma regra da lista de conversas). Excluímos por id (subquery)
  # as conversas WhatsApp que o papel NÃO deixa ver, em vez de reescrever o
  # filtro de inbox_id: assim compõe em AND com qualquer filtro adicional (ex.:
  # apply_inbox_id_filter) sem risco de sobrescrita.
  def apply_role_visibility_to_conversations(conversations_query)
    return conversations_query if Conversations::RoleVisibility.unrestricted?(account_user)
    return conversations_query if accessable_whatsapp_inbox_ids.empty?

    whatsapp_scope = conversations_query.where(inbox_id: accessable_whatsapp_inbox_ids)
    conversations_query.where.not(id: hidden_conversation_ids_subquery(whatsapp_scope))
  end

  # Mesma regra na busca de mensagens (GIN/LIKE). Filtro POSITIVO: outras caixas
  # OU conversas visíveis (subconsulta). Excluir por NOT IN a lista de ocultas
  # cresceria com a caixa inteira (todo mundo que não é o usuário); a lista de
  # visíveis tem o tamanho do que ele acessa. Os dois lados são subconsultas SQL,
  # sem lista em memória.
  def apply_role_visibility_to_messages(messages_query)
    return messages_query if Conversations::RoleVisibility.unrestricted?(account_user)
    return messages_query if accessable_whatsapp_inbox_ids.empty?

    whatsapp_ids = accessable_whatsapp_inbox_ids
    whatsapp_conversations = current_account.conversations.where(inbox_id: whatsapp_ids)
    visible_ids = Conversations::RoleVisibility.filter(whatsapp_conversations, current_user, account_user: account_user).select(:id)

    messages_query.where.not(inbox_id: whatsapp_ids)
                  .or(messages_query.where(inbox_id: whatsapp_ids, conversation_id: visible_ids))
  end

  # WHERE id IN (SELECT id FROM conversations WHERE ... AND id NOT IN (visíveis)):
  # o Postgres resolve tudo numa query só, sem lista em memória. Parte de um
  # escopo já restrito por accessable_inbox_ids (não a caixa inteira).
  def hidden_conversation_ids_subquery(whatsapp_conversations)
    visible_scope = Conversations::RoleVisibility.filter(whatsapp_conversations, current_user, account_user: account_user)
    whatsapp_conversations.where.not(id: visible_scope).select(:id)
  end
end
