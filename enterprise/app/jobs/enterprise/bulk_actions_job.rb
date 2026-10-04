# As ações em massa agem em qualquer display_id enviado. Numa caixa WhatsApp só
# agem nas conversas que o usuário enxerga pelo papel (um Setor não se atribui à
# conversa de um colega pra passar a enxergá-la); outras caixas ficam como estão.
module Enterprise::BulkActionsJob
  def records_to_updated(ids)
    records = super
    return records if records.nil?

    account_user = @account.account_users.find_by(user_id: Current.user.id)
    Conversations::RoleVisibility.restrict_to_visible(records, Current.user, account_user: account_user)
  end

  # Adalink: quem tem visão restrita só se atribui a conversa sem responsável e só reatribui/tira
  # o responsável se for o responsável atual (ConversationPolicy#change_assignee?), em todos os
  # canais. As outras ações do mesmo pedido (status, time, etiquetas) seguem normais.
  def conversation_update_params(conversation, params)
    key = params.keys.find { |name| name.to_s == 'assignee_id' }
    return super if key.nil?
    return super if assignee_change_allowed?(conversation, params[key])

    super(conversation, params.except(key))
  end

  private

  def assignee_change_allowed?(conversation, new_assignee_id)
    @assignment_account_user ||= @account.account_users.find_by(user_id: Current.user.id)
    ConversationPolicy.for_user(Current.user, conversation, account_user: @assignment_account_user).change_assignee?(new_assignee_id)
  end
end
