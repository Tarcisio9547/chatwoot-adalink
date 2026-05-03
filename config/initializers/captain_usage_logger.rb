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

  def make_api_call(model:, messages:, schema: nil, tools: [])
    response = super(model: model, messages: messages, schema: schema, tools: tools)
    post_usage_to_crm(model, response) if response.is_a?(Hash) && response[:usage].present?
    response
  end

  def post_usage_to_crm(model, response)
    url = ENV.fetch('CRM_LOG_USAGE_URL', nil)
    secret = ENV.fetch('CRM_LOG_USAGE_SECRET', nil)
    return if url.blank? || secret.blank?

    payload = {
      chatwoot_account_id: account.id,
      agent_email: nil, # TODO: plumbar current user quando disparar de UI; nil em jobs background
      feature: event_name.to_s,
      model: model,
      input_tokens: response[:usage]['prompt_tokens'].to_i,
      output_tokens: response[:usage]['completion_tokens'].to_i,
      uses_own_key: openai_hook.present?,
      metadata: {
        conversation_id: conversation&.display_id,
        channel_type: conversation&.inbox&.channel_type
      }.compact
    }

    Thread.new do
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.read_timeout = 5
      http.open_timeout = 3
      req = Net::HTTP::Post.new(uri.request_uri, {
                                  'Content-Type' => 'application/json',
                                  'x-captain-secret' => secret
                                })
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
