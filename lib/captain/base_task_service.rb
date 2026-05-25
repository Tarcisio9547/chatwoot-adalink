class Captain::BaseTaskService
  include Integrations::LlmInstrumentation
  include Captain::ToolInstrumentation

  # gpt-4o-mini supports 128,000 tokens
  # 1 token is approx 4 characters
  # sticking with 120000 to be safe
  # 120000 * 4 = 480,000 characters (rounding off downwards to 400,000 to be safe)
  TOKEN_LIMIT = 400_000

  # Mantido pra retrocompat com callers externos. Subclasses devem deixar
  # `make_api_call` resolver o modelo via `feature_key` — assim respeitam
  # `account.captain_<feature>_model` (preferência setada pelo admin no UI).
  GPT_MODEL = Llm::Config::DEFAULT_MODEL

  # Prepend enterprise module to subclasses when they're defined.
  # This ensures the enterprise perform wrapper is applied even when
  # subclasses define their own perform method, since prepend puts
  # the module before the class in the ancestor chain.
  def self.inherited(subclass)
    super
    subclass.prepend_mod_with('Captain::BaseTaskService')
  end

  pattr_initialize [:account!, { conversation_display_id: nil }]

  private

  def event_name
    raise NotImplementedError, "#{self.class} must implement #event_name"
  end

  # Feature do config/llm.yml que governa a escolha do modelo pra essa service.
  # Default 'editor' cobre rewrite/reply_suggestion/summary (geração de texto
  # genérica). Subclasses override quando o domínio bate em outra feature
  # (ex: LabelSuggestionService → 'label_suggestion').
  def feature_key
    'editor'
  end

  def conversation
    @conversation ||= account.conversations.find_by(display_id: conversation_display_id)
  end

  # Modelo a usar: preferência salva na account (via UI Configurações → Captain) >
  # default declarado em llm.yml pra essa feature > DEFAULT_MODEL global.
  # Subclasses internas podem override (ex: ConversationCompletion lê
  # CAPTAIN_OPEN_AI_MODEL InstallationConfig pra ficar invariante à preferência
  # do tenant).
  def model_for_feature
    @model_for_feature ||= begin
      feature = feature_key.to_s
      preferred = if Llm::Models.feature_keys.include?(feature)
                    account.public_send("captain_#{feature}_model")
                  else
                    Rails.logger.warn("[Captain] feature '#{feature}' não declarada em config/llm.yml — usando DEFAULT_MODEL")
                    nil
                  end
      (preferred.presence || Llm::Config::DEFAULT_MODEL).to_s
    end
  end

  # Provider canônico pro model_id passado (lookup em llm.yml).
  # Default sem argumento: o do model_for_feature. Subclasses chamam essa
  # versão parametrizada quando precisam resolver provider de um model
  # diferente (ex: ConversationCompletion passa model explícito).
  def provider_for(model_id)
    Llm::Config.provider_for(model_id)
  end

  # Atalho pro provider do model_for_feature — usado em gate checks (api_key_configured?)
  # e no metadata de instrumentação.
  def provider
    @provider ||= provider_for(model_for_feature)
  end

  # Endpoint pro provider — InstallationConfig override > default oficial.
  # Adiciona /v1 se ainda não tiver (compat com endpoints custom).
  def api_base_for(provider_id)
    @api_bases ||= {}
    @api_bases[provider_id] ||= begin
      _, configured = Llm::Config.system_credentials_for(provider_id)
      endpoint = (configured.presence || Llm::Config.default_api_base_for(provider_id)).chomp('/')
      endpoint.end_with?('/v1') ? endpoint : "#{endpoint}/v1"
    end
  end

  # API key cascata por provider: hook account-level > InstallationConfig system.
  # Subclasses internas (translate, completion) override pra forçar system-only.
  def api_key_for(provider_id)
    @api_keys ||= {}
    @api_keys[provider_id] ||= account_hook_for(provider_id)&.settings&.dig('api_key') ||
                               system_api_key_for(provider_id)
  end

  def account_hook_for(provider_id)
    @account_hooks ||= {}
    @account_hooks[provider_id] ||= account.hooks.find_by(
      app_id: Llm::Config.hook_app_id_for(provider_id),
      status: 'enabled'
    )
  end

  def system_api_key_for(provider_id)
    @system_keys ||= {}
    return @system_keys[provider_id] if @system_keys.key?(provider_id)

    key, _ = Llm::Config.system_credentials_for(provider_id)
    @system_keys[provider_id] = key
  end

  # Retrocompat — versões no-arg usam o provider do model_for_feature.
  # Subclasses internas override `api_key` pra fixar uma fonte específica.
  def api_key
    api_key_for(provider)
  end

  def api_base
    api_base_for(provider)
  end

  # Retrocompat: subclasses internas (TranslateQuery, ConversationCompletion)
  # referenciam `openai_hook` — sempre o hook OpenAI, independente do provider
  # atual. Preservado pra não quebrar elas.
  def openai_hook
    @openai_hook ||= account.hooks.find_by(app_id: 'openai', status: 'enabled')
  end

  # Retrocompat — system key OpenAI (legacy callers do TranslateQuery e
  # ConversationCompletion que assumiam OpenAI single-provider).
  def system_api_key
    @system_api_key_legacy ||= begin
      key, _ = Llm::Config.system_credentials_for('openai')
      key
    end
  end

  # Aceita `model:` opcional. Quando omitido, resolve via `feature_key` +
  # preferência da account. Provider é derivado do model_id real — fica
  # sincronizado mesmo quando caller passa model explícito.
  def make_api_call(messages:, model: nil, schema: nil, tools: [])
    # Community edition prerequisite checks
    # Enterprise module handles these with more specific error messages (cloud vs self-hosted)
    return { error: I18n.t('captain.disabled'), error_code: 403 } unless captain_tasks_enabled?
    return { error: I18n.t('captain.api_key_missing'), error_code: 401 } unless api_key_configured?

    model_id = model.presence || model_for_feature
    provider_id = provider_for(model_id)

    instrumentation_params = build_instrumentation_params(model_id, messages, provider_id)
    instrumentation_method = tools.any? ? :instrument_tool_session : :instrument_llm_call

    response = send(instrumentation_method, instrumentation_params) do
      execute_ruby_llm_request(model: model_id, provider: provider_id, messages: messages, schema: schema, tools: tools)
    end

    return response unless build_follow_up_context? && response[:message].present?

    response.merge(follow_up_context: build_follow_up_context(messages, response))
  end

  def execute_ruby_llm_request(model:, provider:, messages:, schema: nil, tools: [])
    # Subclasses override `api_key_for(provider)` quando querem fonte custom
    # (ex: TranslateQuery / ConversationCompletion preferem system key).
    Llm::Config.with_api_key(api_key_for(provider), api_base: api_base_for(provider), provider: provider) do |context|
      chat = build_chat(context, model: model, provider: provider, messages: messages, schema: schema, tools: tools)

      conversation_messages = messages.reject { |m| m[:role] == 'system' }
      return { error: 'No conversation messages provided', error_code: 400, request_messages: messages } if conversation_messages.empty?

      add_messages_if_needed(chat, conversation_messages)
      build_ruby_llm_response(chat.ask(conversation_messages.last[:content]), messages)
    end
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: account).capture_exception
    { error: e.message, request_messages: messages }
  end

  def build_chat(context, model:, provider:, messages:, schema: nil, tools: [])
    # Passa `provider:` explícito — evita ambiguidade na resolução do model_id
    # quando o mesmo nome existe em mais de um provider.
    chat = context.chat(model: model, provider: provider)
    system_msg = messages.find { |m| m[:role] == 'system' }
    chat.with_instructions(system_msg[:content]) if system_msg
    chat.with_schema(schema) if schema

    if tools.any?
      tools.each { |tool| chat = chat.with_tool(tool) }
      chat.on_end_message { |message| record_generation(chat, message, model) }
    end

    chat
  end

  def add_messages_if_needed(chat, conversation_messages)
    return if conversation_messages.length == 1

    conversation_messages[0...-1].each do |msg|
      chat.add_message(role: msg[:role].to_sym, content: msg[:content])
    end
  end

  def build_ruby_llm_response(response, messages)
    {
      message: response.content,
      usage: {
        'prompt_tokens' => response.input_tokens,
        'completion_tokens' => response.output_tokens,
        'total_tokens' => (response.input_tokens || 0) + (response.output_tokens || 0)
      },
      request_messages: messages
    }
  end

  def build_instrumentation_params(model, messages, provider_id = nil)
    {
      span_name: "llm.#{event_name}",
      account_id: account.id,
      conversation_id: conversation&.display_id,
      feature_name: event_name,
      model: model,
      messages: messages,
      temperature: nil,
      metadata: instrumentation_metadata(provider_id)
    }
  end

  def instrumentation_metadata(provider_id = nil)
    {
      channel_type: conversation&.inbox&.channel_type,
      provider: provider_id || provider
    }.compact
  end

  def conversation_messages(start_from: 0)
    messages = []
    character_count = start_from

    conversation.messages
                .where(message_type: [:incoming, :outgoing])
                .where(private: false)
                .reorder('id desc')
                .each do |message|
      content = message.content_for_llm
      next if content.blank?
      break if character_count + content.length > TOKEN_LIMIT

      messages.prepend({ role: (message.incoming? ? 'user' : 'assistant'), content: content })
      character_count += content.length
    end

    messages
  end

  def captain_tasks_enabled?
    account.feature_enabled?('captain_tasks')
  end

  def api_key_configured?
    api_key.present?
  end

  def prompt_from_file(file_name)
    Rails.root.join('lib/integrations/openai/openai_prompts', "#{file_name}.liquid").read
  end

  # Follow-up context for client-side refinement
  def build_follow_up_context?
    # FollowUpService should return its own updated context
    !is_a?(Captain::FollowUpService)
  end

  def build_follow_up_context(messages, response)
    {
      event_name: event_name,
      original_context: extract_original_context(messages),
      last_response: response[:message],
      conversation_history: [],
      channel_type: conversation&.inbox&.channel_type
    }
  end

  def extract_original_context(messages)
    # Get the most recent user message for follow-up context
    user_msg = messages.reverse.find { |m| m[:role] == 'user' }
    user_msg ? user_msg[:content] : nil
  end
end
Captain::BaseTaskService.prepend_mod_with('Captain::BaseTaskService')
