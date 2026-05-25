class Integrations::LlmBaseService
  include Integrations::LlmInstrumentation

  # gpt-4o-mini supports 128,000 tokens
  # 1 token is approx 4 characters
  # sticking with 120000 to be safe
  # 120000 * 4 = 480,000 characters (rounding off downwards to 400,000 to be safe)
  TOKEN_LIMIT = 400_000
  GPT_MODEL = Llm::Config::DEFAULT_MODEL
  ALLOWED_EVENT_NAMES = %w[summarize reply_suggestion fix_spelling_grammar casual professional friendly confident
                           straightforward improve].freeze
  CACHEABLE_EVENTS = %w[].freeze

  pattr_initialize [:hook!, :event!]

  def perform
    return nil unless valid_event_name?

    return value_from_cache if value_from_cache.present?

    response = send("#{event_name}_message")
    save_to_cache(response) if response.present?

    response
  end

  private

  def event_name
    event['name']
  end

  def cache_key
    return nil unless event_is_cacheable?

    return nil unless conversation

    # since the value from cache depends on the conversation last_activity_at, it will always be fresh
    format(::Redis::Alfred::OPENAI_CONVERSATION_KEY, event_name: event_name, conversation_id: conversation.id,
                                                     updated_at: conversation.last_activity_at.to_i)
  end

  def value_from_cache
    return nil unless event_is_cacheable?
    return nil if cache_key.blank?

    deserialize_cached_value(Redis::Alfred.get(cache_key))
  end

  def deserialize_cached_value(value)
    return nil if value.blank?

    JSON.parse(value, symbolize_names: true)
  rescue JSON::ParserError
    # If json parse failed, returning the value as is will fail too
    # since we access the keys as symbols down the line
    # So it's best to return nil
    nil
  end

  def save_to_cache(response)
    return nil unless event_is_cacheable?

    # Serialize to JSON
    # This makes parsing easy when response is a hash
    Redis::Alfred.setex(cache_key, response.to_json)
  end

  def conversation
    @conversation ||= hook.account.conversations.find_by(display_id: event['data']['conversation_display_id'])
  end

  def valid_event_name?
    # self.class::ALLOWED_EVENT_NAMES is way to access ALLOWED_EVENT_NAMES defined in the class hierarchy of the current object.
    # This ensures that if ALLOWED_EVENT_NAMES is updated elsewhere in it's ancestors, we access the latest value.
    self.class::ALLOWED_EVENT_NAMES.include?(event_name)
  end

  def event_is_cacheable?
    # self.class::CACHEABLE_EVENTS is way to access CACHEABLE_EVENTS defined in the class hierarchy of the current object.
    # This ensures that if CACHEABLE_EVENTS is updated elsewhere in it's ancestors, we access the latest value.
    self.class::CACHEABLE_EVENTS.include?(event_name)
  end

  # Default api_base — usado quando o provider não pode ser derivado.
  # Provider-aware lookup vai em api_base_for(provider_id).
  def api_base
    api_base_for('openai')
  end

  # Endpoint per-provider — pra integrations payloads que carregam model de
  # provider não-OpenAI (ex: hook configurado com 'deepseek/deepseek-v4-flash').
  def api_base_for(provider_id)
    _, configured = Llm::Config.system_credentials_for(provider_id)
    endpoint = (configured.presence || Llm::Config.default_api_base_for(provider_id)).chomp('/')
    endpoint.end_with?('/v1') ? endpoint : "#{endpoint}/v1"
  end

  def make_api_call(body)
    parsed_body = JSON.parse(body)
    instrumentation_params = build_instrumentation_params(parsed_body)

    instrument_llm_call(instrumentation_params) do
      execute_ruby_llm_request(parsed_body)
    end
  end

  def execute_ruby_llm_request(parsed_body)
    messages = parsed_body['messages']
    model = parsed_body['model']
    # Provider derivado do model — se o hook for configurado com modelo
    # OpenRouter (ex: deepseek/deepseek-v4-flash), routa via OpenRouter.
    # Fallback 'openai' (comportamento legacy) pra qualquer model desconhecido.
    provider_id = Llm::Config.provider_for(model)

    Llm::Config.with_api_key(hook.settings['api_key'], api_base: api_base_for(provider_id), provider: provider_id) do |context|
      chat = context.chat(model: model, provider: provider_id)
      setup_chat_with_messages(chat, messages)
    end
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: hook.account).capture_exception
    build_error_response_from_exception(e, messages)
  end

  def setup_chat_with_messages(chat, messages)
    apply_system_instructions(chat, messages)
    response = send_conversation_messages(chat, messages)
    return { error: 'No conversation messages provided', error_code: 400, request_messages: messages } if response.nil?

    build_ruby_llm_response(response, messages)
  end

  def apply_system_instructions(chat, messages)
    system_msg = messages.find { |m| m['role'] == 'system' }
    chat.with_instructions(system_msg['content']) if system_msg
  end

  def send_conversation_messages(chat, messages)
    conversation_messages = messages.reject { |m| m['role'] == 'system' }

    return nil if conversation_messages.empty?

    return chat.ask(conversation_messages.first['content']) if conversation_messages.length == 1

    add_conversation_history(chat, conversation_messages[0...-1])
    chat.ask(conversation_messages.last['content'])
  end

  def add_conversation_history(chat, messages)
    messages.each do |msg|
      chat.add_message(role: msg['role'].to_sym, content: msg['content'])
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

  def build_instrumentation_params(parsed_body)
    {
      span_name: "llm.#{event_name}",
      account_id: hook.account_id,
      conversation_id: conversation&.display_id,
      feature_name: event_name,
      model: parsed_body['model'],
      messages: parsed_body['messages'],
      temperature: parsed_body['temperature']
    }
  end

  def build_error_response_from_exception(error, messages)
    { error: error.message, request_messages: messages }
  end
end
