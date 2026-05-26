# Patch ruby_llm OpenRouter provider para enviar HTTP-Referer e X-Title.
#
# Por que: OpenRouter usa esses headers pra identificar a aplicação cliente.
# Sem eles, a request perde prioridade no roteamento e analytics ficam sem
# atribuição. Em modelos lentos (DeepSeek V4 Flash), latência adicional pode
# estourar Rack::Timeout default (15s) do Chatwoot.
#
# Por que monkey-patch via prepend: ruby_llm 1.9.x não expõe configuração
# pública pra esses headers no provider OpenRouter. Aguardando upstream
# https://github.com/crmne/ruby_llm — quando suportar nativamente, remover
# este arquivo.
#
# Por que defensivo: este arquivo NÃO pode quebrar o boot do Chatwoot.
# Qualquer falha (gem ausente, namespace mudou, ENV inválido) é logada e
# ignorada — o pior caso é "patch não aplicado", nunca "Chatwoot não sobe".

Rails.application.config.after_initialize do
  begin
    unless defined?(RubyLLM::Providers::OpenRouter)
      Rails.logger.info('[OpenRouterHeaders] RubyLLM::Providers::OpenRouter não definido — patch ignorado')
      next
    end

    referer = ENV.fetch('CAPTAIN_OPENROUTER_REFERER', 'https://chatwoot-production-7b22.up.railway.app')
    app_title = ENV.fetch('CAPTAIN_OPENROUTER_APP_NAME', 'Chatwoot Adalink CRM')

    extra_headers = {
      'HTTP-Referer' => referer,
      'X-Title' => app_title
    }.freeze

    patch_module = Module.new do
      define_method(:headers) do
        original = super()
        # super() pode vir como Hash mutável ou frozen — merge sempre retorna novo Hash.
        original.merge(extra_headers)
      end
    end

    RubyLLM::Providers::OpenRouter.prepend(patch_module)
    Rails.logger.info("[OpenRouterHeaders] Patch aplicado — Referer=#{referer} Title=#{app_title}")
  rescue StandardError => e
    Rails.logger.warn("[OpenRouterHeaders] Falha ao aplicar patch: #{e.class}: #{e.message}")
    # Não re-raise — Chatwoot deve subir mesmo sem o patch.
  end
end
