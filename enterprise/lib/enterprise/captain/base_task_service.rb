# Numa caixa WhatsApp, quem não enxerga a conversa pelo papel (ex.: Setor pedindo
# a conversa de um colega) não executa a tarefa nem chega ao LLM: o resultado
# traz error_code :conversation_not_visible e o controller responde 404. A
# conversa é carregada uma única vez, já com o tipo de canal (mesma consulta que
# o upstream faz), então outras caixas não pagam consulta extra.
module Enterprise::Captain::BaseTaskService
  def perform
    return { error: I18n.t('captain.copilot_limit'), error_code: 429 } unless responses_available?

    unless captain_tasks_enabled?
      return { error: I18n.t('captain.upgrade') } if ChatwootApp.chatwoot_cloud?

      return { error: I18n.t('captain.disabled') }
    end

    return { error: 'Conversation not found', error_code: :conversation_not_visible } if conversation_hidden_from_requester?

    result = super
    increment_usage if successful_result?(result)
    result
  end

  private

  def conversation
    @conversation ||= account.conversations.joins(:inbox)
                             .select('conversations.*, inboxes.channel_type AS inbox_channel_type')
                             .find_by(display_id: conversation_display_id)
  end

  def conversation_hidden_from_requester?
    requester = Current.user
    return false if requester.blank? || conversation.nil?
    return false unless conversation[:inbox_channel_type] == Conversations::RoleVisibility::WHATSAPP_CHANNEL_TYPE

    Conversations::RoleVisibility.visible_members(conversation, [requester]).exclude?(requester)
  end

  def responses_available?
    return true unless ChatwootApp.chatwoot_cloud?

    account.usage_limits[:captain][:responses][:current_available].positive?
  end

  def successful_result?(result)
    result.is_a?(Hash) && result[:message].present? && !result[:error]
  end

  def increment_usage
    Rails.logger.info("[CAPTAIN][#{self.class.name}] Incrementing response usage for account #{account.id}")
    account.increment_response_usage
  end
end
