# Evaluates whether a conversation is complete and can be auto-resolved.
# Used by InboxPendingConversationsResolutionJob to determine if inactive
# conversations should be resolved or handed off to human agents.
#
# NOTE: This service intentionally does NOT count toward Captain usage limits.
# The response excludes the :message key that Enterprise::Captain::BaseTaskService
# checks for usage tracking. This is an internal operational evaluation,
# not a customer-facing value-add, so we don't charge for it.
class Captain::ConversationCompletionService < Captain::BaseTaskService
  RESPONSE_SCHEMA = Captain::ConversationCompletionSchema

  pattr_initialize [:account!, :conversation_display_id!]

  def perform
    content = format_messages_as_string
    return default_incomplete_response('No messages found') if content.blank?

    # Sem `model:`: o base resolve via feature_key (override abaixo). Esse
    # service é interno (não cobra do tenant) então quer modelo system-wide.
    response = make_api_call(
      messages: [
        { role: 'system', content: prompt_from_file('conversation_completion') },
        { role: 'user', content: content }
      ],
      schema: RESPONSE_SCHEMA
    )

    return default_incomplete_response(response[:error]) if response[:error].present?

    parse_response(response[:message])
  end

  private

  def prompt_from_file(file_name)
    Rails.root.join('enterprise/lib/captain/prompts', "#{file_name}.liquid").read
  end

  def format_messages_as_string
    messages = conversation_messages(start_from: 0)
    messages.map do |msg|
      sender_type = msg[:role] == 'user' ? 'Customer' : 'Assistant'
      "#{sender_type}: #{msg[:content]}"
    end.join("\n")
  end

  def parse_response(message)
    return default_incomplete_response('Invalid response format') unless message.is_a?(Hash)

    {
      complete: message['complete'] == true,
      reason: message['reason'] || 'No reason provided'
    }
  end

  def default_incomplete_response(reason)
    { complete: false, reason: reason }
  end

  # Modelo system-wide: lê CAPTAIN_OPEN_AI_MODEL InstallationConfig pra ficar
  # invariante à preferência do tenant. É feature operacional interna, não
  # customer-facing — Trama decide o modelo, não o tenant.
  def model_for_feature
    @model_for_feature ||= begin
      system_model = InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value
      (system_model.presence || Llm::Config::DEFAULT_MODEL).to_s
    end
  end

  # Prefer the system API key over the account's hook key.
  # Internal operational evaluation — não consome créditos do tenant em hosted.
  # Fallback no hook account-level só pra self-hosted sem system key.
  def api_key_for(provider_id)
    @api_keys_internal ||= {}
    @api_keys_internal[provider_id] ||= system_api_key_for(provider_id).presence ||
                                        account_hook_for(provider_id)&.settings&.dig('api_key')
  end

  def event_name
    'captain.conversation_completion'
  end

  def build_follow_up_context?
    false
  end
end

Captain::ConversationCompletionService.prepend_mod_with('Captain::ConversationCompletionService')
