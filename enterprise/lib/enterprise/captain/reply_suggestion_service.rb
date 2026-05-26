module Enterprise::Captain::ReplySuggestionService
  # Signature alinhada com Captain::BaseTaskService#make_api_call pós-refactor
  # multi-provider: `messages` é o único kwarg obrigatório; `model` opcional
  # (resolução cai no feature_key + account preference quando não passado).
  def make_api_call(messages:, model: nil, tools: [])
    return super unless use_search_tool?

    super(messages: messages, model: model, tools: [build_search_tool])
  end

  private

  def use_search_tool?
    ChatwootApp.chatwoot_cloud? || ChatwootApp.self_hosted_enterprise?
  end

  def prompt_variables
    return super unless use_search_tool?

    super.merge('has_search_tool' => true)
  end

  def build_search_tool
    assistant = conversation&.inbox&.captain_assistant
    Captain::Tools::SearchReplyDocumentationService.new(account: account, assistant: assistant)
  end
end
