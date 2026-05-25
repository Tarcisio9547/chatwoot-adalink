require 'ruby_llm'

# Llm::Config — configuração da abstração RubyLLM no Chatwoot.
#
# Provider-aware: além de OpenAI, suporta OpenRouter (roteamento pra qualquer
# provider que OpenRouter expõe — DeepSeek, Anthropic, Gemini etc).
#
# Pontos de extensão pra adicionar provider novo no futuro:
#   1) Adicionar entrada em PROVIDER_CONFIG
#   2) Adicionar provider em config/llm.yml
#   3) Adicionar InstallationConfig com a key (admin UI) ou env var
#
# Retrocompat: chamadas antigas `with_api_key(key, api_base:)` sem provider
# continuam funcionando — default cai em OpenAI.
module Llm::Config
  DEFAULT_MODEL = 'gpt-4.1-mini'.freeze

  # provider canônico => como mapear no RubyLLM + onde buscar credenciais
  PROVIDER_CONFIG = {
    'openai' => {
      api_key_attr: :openai_api_key,
      api_base_attr: :openai_api_base,
      installation_key: 'CAPTAIN_OPEN_AI_API_KEY',
      installation_base: 'CAPTAIN_OPEN_AI_ENDPOINT',
      hook_app_id: 'openai',
      default_api_base: 'https://api.openai.com'
    },
    'openrouter' => {
      api_key_attr: :openrouter_api_key,
      api_base_attr: :openrouter_api_base,
      installation_key: 'CAPTAIN_OPENROUTER_API_KEY',
      installation_base: 'CAPTAIN_OPENROUTER_ENDPOINT',
      hook_app_id: 'openrouter',
      default_api_base: 'https://openrouter.ai/api/v1'
    }
  }.freeze

  class << self
    def initialized?
      @initialized ||= false
    end

    def initialize!
      return if @initialized

      configure_ruby_llm
      @initialized = true
    end

    def reset!
      @initialized = false
    end

    # Escopa uma chamada RubyLLM com api_key/api_base de UM provider.
    # `provider:` default 'openai' pra retrocompat — chamadas antigas
    # `with_api_key(key, api_base:)` continuam funcionando.
    def with_api_key(api_key, api_base: nil, provider: 'openai')
      cfg = provider_config(provider)
      context = RubyLLM.context do |config|
        # `respond_to?` defensivo: se a versão do ruby_llm não expõe o setter
        # desse provider (improvável em 1.9.2+, mas barato), evita NoMethodError
        # e cai num erro mais útil na hora da chamada `chat.ask`.
        if config.respond_to?("#{cfg[:api_key_attr]}=")
          config.public_send("#{cfg[:api_key_attr]}=", api_key)
        end
        if api_base && config.respond_to?("#{cfg[:api_base_attr]}=")
          config.public_send("#{cfg[:api_base_attr]}=", api_base)
        end
      end

      yield context
    end

    # Provider canônico pra um model_id, lendo de config/llm.yml.
    # Fallback 'openai' pra modelo não declarado (defesa — não quebra runtime).
    def provider_for(model_id)
      Llm::Models.models.dig(model_id.to_s, 'provider').presence || 'openai'
    end

    # System-wide API key + endpoint pra um provider (InstallationConfig).
    # Retorna [api_key, api_base] — caller passa pra with_api_key.
    def system_credentials_for(provider)
      cfg = provider_config(provider)
      api_key = InstallationConfig.find_by(name: cfg[:installation_key])&.value
      api_base = InstallationConfig.find_by(name: cfg[:installation_base])&.value
      [api_key, api_base.presence&.chomp('/')]
    end

    # app_id do Hook pra key per-account (Configurações → Integrações da account).
    def hook_app_id_for(provider)
      provider_config(provider)[:hook_app_id]
    end

    # Endpoint default (não bate em InstallationConfig se nada configurado).
    def default_api_base_for(provider)
      provider_config(provider)[:default_api_base]
    end

    private

    def provider_config(provider)
      PROVIDER_CONFIG[provider.to_s] || PROVIDER_CONFIG['openai']
    end

    # Config global do RubyLLM no boot — popula todas as keys de todos os
    # providers conhecidos. Account-level hooks são aplicados por chamada
    # via `with_api_key` (scoping per-request).
    def configure_ruby_llm
      RubyLLM.configure do |config|
        PROVIDER_CONFIG.each_value do |cfg|
          api_key = InstallationConfig.find_by(name: cfg[:installation_key])&.value
          api_base = InstallationConfig.find_by(name: cfg[:installation_base])&.value

          if api_key.present? && config.respond_to?("#{cfg[:api_key_attr]}=")
            config.public_send("#{cfg[:api_key_attr]}=", api_key)
          end
          if api_base.present? && config.respond_to?("#{cfg[:api_base_attr]}=")
            config.public_send("#{cfg[:api_base_attr]}=", api_base.chomp('/'))
          end
        end
        config.logger = Rails.logger
      end
    end
  end
end
