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
end
