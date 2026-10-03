# As tarefas do Captain leem a conversa por conversation_display_id e mandam o
# texto dela pro LLM. Numa caixa WhatsApp, quem não enxerga a conversa pelo papel
# (ex.: Setor pedindo a conversa de um colega) recebe 404 antes de qualquer
# leitura. Outras caixas e tarefas sem conversa seguem como antes (a policy
# Captain::TasksPolicy não olha a conversa, e ConversationPolicy#show? mudaria o
# comportamento de outros canais).
module Enterprise::Api::V1::Accounts::Captain::TasksController
  def self.prepended(base)
    base.before_action :ensure_conversation_visible
  end

  private

  def ensure_conversation_visible
    return if params[:conversation_display_id].blank?

    conversation = Current.account.conversations.find_by(display_id: params[:conversation_display_id])
    return if conversation.nil? || !conversation.inbox.whatsapp?
    return if Conversations::RoleVisibility.visible_members(conversation, [Current.user]).include?(Current.user)

    head :not_found
  end
end
