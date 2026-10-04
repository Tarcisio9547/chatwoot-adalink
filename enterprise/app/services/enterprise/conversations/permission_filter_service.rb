module Enterprise::Conversations::PermissionFilterService
  def perform
    return filter_by_permissions(permissions) if user_has_custom_role?

    super
  end

  private

  def user_has_custom_role?
    user_role == 'agent' && account_user&.custom_role_id.present?
  end

  def permissions
    account_user&.permissions || []
  end

  def filter_by_permissions(permissions)
    # Permission-based filtering with hierarchy
    # conversation_manage > conversation_unassigned_manage > conversation_participating_manage
    if permissions.include?('conversation_manage')
      accessible_conversations
    elsif permissions.include?('conversation_unassigned_manage')
      filter_unassigned_and_mine
    elsif permissions.include?('conversation_participating_manage')
      filter_mine_and_participating
    else
      Conversation.none
    end
  end

  def filter_unassigned_and_mine
    mine = accessible_conversations.assigned_to(user)
    unassigned = accessible_conversations.unassigned

    Conversation.from("(#{mine.to_sql} UNION #{unassigned.to_sql} UNION #{participating_conversations.to_sql}) as conversations")
                .where(account_id: account.id)
  end

  def filter_mine_and_participating
    accessible_conversations.assigned_to(user).or(participating_conversations)
  end

  # Adalink: quem foi adicionado como participante vê a conversa em qualquer
  # visibilidade (Minhas, Não atribuídas), mesmo atribuída a outra pessoa. Mesmo
  # padrão do Conversations::RoleVisibility.filter. Só as conversas em que o
  # usuário é participante: o resto continua barrado.
  def participating_conversations
    participant_ids = ConversationParticipant.where(user_id: user.id).select(:conversation_id)
    accessible_conversations.where(id: participant_ids)
  end

  # A base consulta os participantes a cada chamada; aqui ela roda até 4 vezes
  # por requisição, então guarda o resultado.
  def accessible_conversations
    @accessible_conversations ||= super
  end
end
