# frozen_string_literal: true

# Adalink-CRM Custom: instrumenta Captain (BaseTaskService) pra postar tokens/custo
# pra uma Edge Function do Supabase (CRM Adalink) que escreve em ai_usage_logs.
#
# Permite o dashboard tenant-side do CRM mostrar consumo do Captain (que
# normalmente só vai pra Langfuse via OpenTelemetry).
#
# Implementado via prepend em initializer pra evitar modificar lib/captain/
# diretamente — sobrevive a `git pull` do upstream Chatwoot sem merge conflict.
#
# Configuração via ENV:
#   CRM_LOG_USAGE_URL    — endpoint Edge Function (https://<project>.supabase.co/functions/v1/log-captain-usage)
#   CRM_LOG_USAGE_SECRET — shared secret (deve bater com CAPTAIN_LOG_SECRET na Edge Function)
#
# Se ENVs não setadas: skip silencioso, Captain segue funcionando normal.

module CaptainUsageLogger
  private

  # Signature bate com Captain::BaseTaskService#make_api_call pós-refactor
  # multi-provider: `messages` é o único kwarg obrigatório; `model` opcional.
  def make_api_call(messages:, model: nil, schema: nil, tools: [])
    response = super(messages: messages, model: model, schema: schema, tools: tools)
    return response unless response.is_a?(Hash) && response[:usage].present?

    # Resolve qual modelo/provider o base realmente usou. Quando caller passou
    # `model:` explícito, prevalece; senão cai no `model_for_feature` (account
    # preference -> llm.yml default -> DEFAULT_MODEL).
    actual_model = (model.presence || model_for_feature).to_s
    actual_provider = Llm::Config.provider_for(actual_model)

    post_usage_to_crm(actual_model, actual_provider, response)
    response
  end

  def post_usage_to_crm(model, provider_id, response)
    url = ENV.fetch('CRM_LOG_USAGE_URL', nil)
    secret = ENV.fetch('CRM_LOG_USAGE_SECRET', nil)
    return if url.blank? || secret.blank?

    dispatch_usage_log(url, secret, build_usage_payload(model, provider_id, response))
  end

  def build_usage_payload(model, provider_id, response)
    {
      chatwoot_account_id: account.id,
      agent_email: nil, # TODO: plumbar current user quando disparar de UI; nil em jobs background
      feature: event_name.to_s,
      # v2 do log-captain-usage: campo `provider` é opcional, default 'openai'.
      # Mandando explícito garante lookup correto em ai_model_pricing.
      provider: provider_id,
      model: model,
      input_tokens: response[:usage]['prompt_tokens'].to_i,
      output_tokens: response[:usage]['completion_tokens'].to_i,
      uses_own_key: account.hooks.exists?(
        app_id: Llm::Config.hook_app_id_for(provider_id), status: 'enabled'
      ),
      metadata: {
        conversation_id: conversation&.display_id,
        channel_type: conversation&.inbox&.channel_type,
        provider: provider_id
      }.compact
    }
  end

  def dispatch_usage_log(url, secret, payload)
    Thread.new do
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.read_timeout = 5
      http.open_timeout = 3
      req = Net::HTTP::Post.new(uri.request_uri,
                                'Content-Type' => 'application/json',
                                'x-captain-secret' => secret)
      req.body = payload.to_json
      http.request(req)
    rescue StandardError => e
      Rails.logger.error("[CaptainUsageLog] post failed: #{e.class}: #{e.message}")
    end
  end
end

# `to_prepare` re-executa em cada reload de código (dev mode) e uma vez em prod.
# Garante que o prepend sobrevive a class reloads.
Rails.application.config.to_prepare do
  require 'net/http'
  Captain::BaseTaskService.prepend(CaptainUsageLogger) unless Captain::BaseTaskService.include?(CaptainUsageLogger)
end
