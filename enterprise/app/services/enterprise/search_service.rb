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

  # Adalink: busca avançada (Elasticsearch) segue a mesma regra de #2083 —
  # na caixa WhatsApp Cloud, só devolve mensagens de conversas visíveis ao
  # papel do usuário. Outras caixas continuam sem restrição adicional.
  #
  # Performance: sai cedo (nenhuma query extra) para admin e agente sem
  # papel restrito. Usa filtro POSITIVO (_or com inbox_id das caixas
  # não-WhatsApp + conversation_id das conversas WhatsApp visíveis), em vez
  # de excluir por "not" a lista de ocultas — o Searchkick/Elasticsearch tem
  # limite de 65.536 termos por cláusula "not in", e a lista de ocultas pode
  # crescer sem limite (todo mundo que não é o dono), enquanto a lista de
  # visíveis (do próprio usuário) é naturalmente pequena.
  #
  # Não reescreve conditions[:inbox_id] (o que colidiria com
  # apply_inbox_filter, que roda depois e pode sobrescrever essa chave):
  # a condição vai em conditions[:_or], que compõe em AND com o resto.
  def apply_role_visibility_to_where_conditions(conditions)
    return conditions if Conversations::RoleVisibility.unrestricted?(current_user, current_account.id)

    whatsapp_inbox_ids = current_account.inboxes.where(channel_type: 'Channel::Whatsapp').pluck(:id)
    whatsapp_inbox_ids &= accessable_inbox_ids unless should_skip_inbox_filtering?
    return conditions if whatsapp_inbox_ids.empty?

    other_inbox_ids = (conditions[:inbox_id] || current_account.inboxes.pluck(:id)) - whatsapp_inbox_ids
    whatsapp_conversations = current_account.conversations.where(inbox_id: whatsapp_inbox_ids)
    visible_ids = Conversations::RoleVisibility.filter(whatsapp_conversations, current_user, current_account).pluck(:id)

    conditions[:_or] = [{ inbox_id: other_inbox_ids }, { conversation_id: visible_ids }]
    conditions
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
