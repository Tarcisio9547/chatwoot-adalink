module Enterprise::SearchService
  def advanced_search
    where_conditions = build_where_conditions
    apply_filters(where_conditions)

    Message.search(
      search_query,
      fields: %w[content attachments.transcribed_text content_attributes.email.subject],
      where: where_conditions,
      order: { created_at: :desc },
      page: params[:page] || 1,
      per_page: 15
    )
  end

  private

  def build_where_conditions
    conditions = { account_id: current_account.id }
    conditions[:inbox_id] = accessable_inbox_ids unless should_skip_inbox_filtering?
    apply_role_visibility_to_where_conditions(conditions)
  end

  # Teto de conversation_id enviados ao Elasticsearch por busca no papel "Sem
  # atendente" (que enxerga toda conversa sem atendente da conta). Passando
  # disso, ficam as mais recentes por last_activity_at e o corte vai pro log.
  ROLE_VISIBILITY_CONVERSATION_LIMIT = 10_000

  # Na caixa WhatsApp Cloud a busca avançada só devolve mensagens de conversas
  # visíveis ao papel do usuário (mesma regra do SearchService). Admin e agente
  # sem papel restrito saem cedo, sem consulta extra.
  #
  # O filtro é POSITIVO (_or: inbox_id das outras caixas + conversation_id das
  # WhatsApp visíveis): o Elasticsearch limita a 65.536 termos por cláusula
  # "not in", e a lista de ocultas cresce com a conta toda. A condição vai em
  # conditions[:_or], que compõe em AND e não colide com apply_inbox_filter
  # (que sobrescreve conditions[:inbox_id]).
  def apply_role_visibility_to_where_conditions(conditions)
    return conditions if Conversations::RoleVisibility.unrestricted?(current_user, current_account.id, account_user: account_user)

    whatsapp_inbox_ids = current_account.inboxes.where(channel_type: 'Channel::Whatsapp').pluck(:id)
    whatsapp_inbox_ids &= accessable_inbox_ids unless should_skip_inbox_filtering?
    return conditions if whatsapp_inbox_ids.empty?

    other_inbox_ids = (conditions[:inbox_id] || current_account.inboxes.pluck(:id)) - whatsapp_inbox_ids
    visible_ids = visible_conversation_ids(since_scoped_whatsapp_conversations(whatsapp_inbox_ids))

    conditions[:_or] = [{ inbox_id: other_inbox_ids }, { conversation_id: visible_ids }]
    conditions
  end

  # Só o limite inicial do período: uma mensagem criada depois de `since`
  # implica last_activity_at >= since, então nenhuma conversa legítima sai.
  # Um limite final por last_activity_at esconderia mensagens do período em
  # conversas com atividade posterior, então ele não é aplicado.
  def since_scoped_whatsapp_conversations(whatsapp_inbox_ids)
    current_account.conversations.where(inbox_id: whatsapp_inbox_ids)
                   .where('conversations.last_activity_at >= ?', enforce_time_limit(params[:since]))
  end

  def visible_conversation_ids(whatsapp_conversations)
    visible = Conversations::RoleVisibility.filter(whatsapp_conversations, current_user, current_account)
    ids = visible.reorder(last_activity_at: :desc).limit(ROLE_VISIBILITY_CONVERSATION_LIMIT + 1).pluck(:id)
    return ids if ids.size <= ROLE_VISIBILITY_CONVERSATION_LIMIT

    Rails.logger.warn "Advanced search role visibility list cut at the limit of #{ROLE_VISIBILITY_CONVERSATION_LIMIT} " \
                      "conversations (account #{current_account.id}, user #{current_user.id})"
    ids.first(ROLE_VISIBILITY_CONVERSATION_LIMIT)
  end

  def apply_filters(where_conditions)
    apply_from_filter(where_conditions)
    apply_time_range_filter(where_conditions)
    apply_inbox_filter(where_conditions)
  end

  def apply_from_filter(where_conditions)
    sender_type, sender_id = parse_from_param(params[:from])
    return unless sender_type && sender_id

    where_conditions[:sender_type] = sender_type
    where_conditions[:sender_id] = sender_id
  end

  def parse_from_param(from_param)
    return [nil, nil] unless from_param&.match?(/\A(contact|agent):\d+\z/)

    type, id = from_param.split(':')
    sender_type = type == 'agent' ? 'User' : 'Contact'
    [sender_type, id.to_i]
  end

  def apply_time_range_filter(where_conditions)
    time_conditions = {}
    time_conditions[:gte] = enforce_time_limit(params[:since])
    time_conditions[:lte] = cap_until_time(params[:until]) if params[:until].present?

    where_conditions[:created_at] = time_conditions if time_conditions.any?
  end

  def cap_until_time(until_param)
    max_future = 90.days.from_now
    requested_time = Time.zone.at(until_param.to_i)

    [requested_time, max_future].min
  end

  def enforce_time_limit(since_param)
    max_lookback = Limits::MESSAGE_SEARCH_TIME_RANGE_LIMIT_DAYS.days.ago

    if since_param.present?
      requested_time = Time.zone.at(since_param.to_i)
      # Silently cap to max_lookback if requested time is too far back
      [requested_time, max_lookback].max
    else
      max_lookback
    end
  end

  def apply_inbox_filter(where_conditions)
    return if params[:inbox_id].blank?

    inbox_id = params[:inbox_id].to_i
    return if inbox_id.zero?
    return unless validate_inbox_access(inbox_id)

    where_conditions[:inbox_id] = inbox_id
  end

  def validate_inbox_access(inbox_id)
    return true if should_skip_inbox_filtering?

    accessable_inbox_ids.include?(inbox_id)
  end
end
