# Adalink: #2084 — na caixa WhatsApp Cloud, o aviso de conversa criada (e o
# handoff de bot) vai só para membros cujo papel permite ver a conversa
# (mesma regra de RoleVisibility usada pela busca em #2083). Outras caixas
# continuam avisando todos os membros, igual ao comportamento upstream —
# cada override chama `super` nesse caso.
module Enterprise::NotificationListener
  def conversation_created(event)
    conversation, account = extract_conversation_and_account(event)
    return super unless conversation.inbox.whatsapp?

    notify_members(conversation, account)
  end

  def conversation_bot_handoff(event)
    conversation, account = extract_conversation_and_account(event)
    return super unless conversation.inbox.whatsapp?

    notify_members(conversation, account)
  end

  private

  def notify_members(conversation, account)
    return if conversation.pending?

    visible_members(conversation).each do |agent|
      NotificationBuilder.new(
        notification_type: 'conversation_creation',
        user: agent,
        account: account,
        primary_actor: conversation
      ).perform
    end
  end

  def visible_members(conversation)
    Conversations::RoleVisibility.visible_members(conversation, conversation.inbox.members)
  end
end
