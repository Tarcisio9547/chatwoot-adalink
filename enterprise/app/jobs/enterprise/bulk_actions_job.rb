# As ações em massa agem em qualquer display_id enviado. Numa caixa WhatsApp só
# agem nas conversas que o usuário enxerga pelo papel (um Setor não se atribui à
# conversa de um colega pra passar a enxergá-la). Adalink: quando o pedido muda responsável, time ou
# status, quem tem visão restrita só age no que enxerga em TODOS os canais; rótulos e soneca ficam
# como estavam nas outras caixas.
module Enterprise::BulkActionsJob
  RESTRICTED_FIELDS = %w[assignee_id team_id status].freeze

  def records_to_updated(ids)
    records = super
    return records if records.nil?

    # Guarda quem pediu: os callbacks de cada update podem limpar o Current no meio do laço.
    @actor = Current.user
    account_user = account_user_for_policy
    records = Conversations::RoleVisibility.restrict_to_visible(records, @actor, account_user: account_user)
    return records unless changes_assignee_team_or_status?

    visible_ids = records.select { |conversation| policy_for(conversation).change_status? }.map(&:id)
    records.where(id: visible_ids)
  end

  # Adalink: quem tem visão restrita só se atribui a conversa sem responsável e só reatribui/tira
  # o responsável se for o responsável atual (ConversationPolicy#change_assignee?), e só troca de time
  # se isso não tirar o dono de outra pessoa (change_team?), em todos os canais. As outras ações do
  # mesmo pedido (status, etiquetas) seguem normais.
  def conversation_update_params(conversation, params)
    params = without_forbidden(params, 'assignee_id') { |value| policy_for(conversation).change_assignee?(value) }
    params = without_forbidden(params, 'team_id') { |value| policy_for(conversation).change_team?(team_for(value)) }
    super(conversation, params)
  end

  private

  def without_forbidden(params, field)
    key = params.keys.find { |name| name.to_s == field }
    return params if key.nil? || yield(params[key])

    params.except(key)
  end

  def changes_assignee_team_or_status?
    fields = @params[:fields]
    fields.present? && fields.keys.any? { |name| RESTRICTED_FIELDS.include?(name.to_s) }
  end

  def team_for(team_id)
    team_id.present? ? @account.teams.find_by(id: team_id) : nil
  end

  def account_user_for_policy
    @account_user_for_policy ||= @account.account_users.find_by(user_id: @actor.id)
  end

  def policy_for(conversation)
    ConversationPolicy.for_user(@actor, conversation, account_user: account_user_for_policy)
  end
end
