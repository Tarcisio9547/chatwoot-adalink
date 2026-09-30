# Adalink: #2084 — na caixa WhatsApp Cloud, o aviso de conversa criada vai só
# para membros cujo papel permite ver a conversa (mesma regra de RoleVisibility
# usada pela busca em #2083). Outras caixas continuam avisando todos os
# membros, igual ao comportamento upstream.
module Enterprise::NotificationListener
  def conversation_created(event)
    conversation, account = extract_conversation_and_account(event)
    return if conversation.pending?

    notifiable_members(conversation).each do |agent|
      NotificationBuilder.new(
        notification_type: 'conversation_creation',
        user: agent,
        account: account,
        primary_actor: conversation
      ).perform
    end
  end

  private

  def notifiable_members(conversation)
    members = conversation.inbox.members
    return members unless conversation.inbox.whatsapp?

    Conversations::RoleVisibility.visible_members(conversation, members)
  end
end
