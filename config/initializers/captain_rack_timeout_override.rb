# frozen_string_literal: true
#
# Aumenta Rack::Timeout pra rotas Captain (60s) preservando o default (15s)
# pras outras rotas. Cirúrgico — não muda timeout global.
#
# Por que: reply_suggestion faz tool calling (search_documentation no Captain
# Enterprise). Internamente ruby_llm faz 2 round-trips ao LLM:
#   1) primeira chamada → LLM decide chamar tool
#   2) tool executa local (translate + vector search)
#   3) segunda chamada → LLM com resultado do tool gera resposta final
#
# Em modelos lentos (DeepSeek V4 Flash via OpenRouter), a 2ª chamada estoura
# os 15s default do Rack::Timeout, mata a request em Net::HTTP#read_body.
#
# Aumentar global esconderia lentidão real do sistema (qualquer endpoint
# lento passa a ser tolerado). Aumentar SÓ pra `/api/.../captain/` é
# cirúrgico.
#
# Thread-safety: NÃO muta estado da instance global do middleware. Cria
# uma instance NOVA dedicada por request Captain (negligível em alocação).
#
# Defensivo: any failure → logger.warn e Chatwoot sobe normal sem override.

require 'rack-timeout'

module CaptainRackTimeoutOverride
  CAPTAIN_PATH = %r{^/api/v\d+/accounts/\d+/captain/}.freeze
  EXTENDED_TIMEOUT = 60

  def call(env)
    if CAPTAIN_PATH.match?(env['PATH_INFO'].to_s)
      Rack::Timeout.new(@app, service_timeout: EXTENDED_TIMEOUT).call(env)
    else
      super
    end
  end
end

# Em rack-timeout 0.6.x a middleware é a própria `Rack::Timeout` (classe top-level
# do módulo Rack), NÃO `Rack::Timeout::Middleware` — esse último não existe.
# Por isso checamos `is_a?(Class)` pra ter certeza que é instanciável.
Rails.application.config.after_initialize do
  if defined?(Rack::Timeout) && Rack::Timeout.is_a?(Class)
    Rack::Timeout.prepend(CaptainRackTimeoutOverride)
    Rails.logger.info(
      "[CaptainRackTimeout] Override ativo — #{CaptainRackTimeoutOverride::EXTENDED_TIMEOUT}s para rotas /api/v*/accounts/*/captain/*"
    )
  else
    Rails.logger.warn('[CaptainRackTimeout] Rack::Timeout não definido como classe — override ignorado')
  end
rescue StandardError => e
  Rails.logger.warn("[CaptainRackTimeout] Falha ao aplicar override: #{e.class}: #{e.message}")
end
