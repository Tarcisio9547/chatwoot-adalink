# A macro executa em qualquer display_id enviado. Numa caixa WhatsApp só age nas
# conversas que o usuário enxerga pelo papel (um Setor não manda a transcrição da
# conversa de um colega nem se atribui a ela); outras caixas ficam como estão.
module Enterprise::MacrosExecutionJob
  private

  def executable_conversations(account, conversation_ids, user)
    account_user = account.account_users.find_by(user_id: user.id)
    Conversations::RoleVisibility.restrict_to_visible(super, user, account_user: account_user)
  end
end
