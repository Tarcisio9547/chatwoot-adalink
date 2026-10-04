# A macro executa em qualquer display_id enviado. Numa caixa WhatsApp só age nas conversas que o
# usuário enxerga pelo papel (um Setor não manda a transcrição da conversa de um colega nem se atribui a
# ela). Adalink: quem tem visão restrita só executa a macro nas conversas que enxerga (show?), em QUALQUER
# canal: resolver, adiar, mandar mensagem (sai pelo número do colega no WhatsApp Pessoal), nota privada,
# transcrição e webhook não rodam em conversa que ele não vê. Os gates por ação (atribuir, time, status)
# seguem valendo para a conversa visível de outro dono.
module Enterprise::MacrosExecutionJob
  private

  def executable_conversations(account, conversation_ids, user)
    account_user = account.account_users.find_by(user_id: user.id)
    conversations = Conversations::RoleVisibility.restrict_to_visible(super, user, account_user: account_user)
    actionable = conversations.select do |conversation|
      ConversationPolicy.for_user(user, conversation, account_user: account_user).actionable?
    end
    conversations.where(id: actionable.map(&:id))
  end
end
