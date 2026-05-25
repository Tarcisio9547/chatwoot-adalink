# frozen_string_literal: true

# Base service for LLM operations using RubyLLM.
# New features should inherit from this class.
class Llm::BaseAiService
  DEFAULT_MODEL = Llm::Config::DEFAULT_MODEL
  DEFAULT_TEMPERATURE = 1.0

  attr_reader :model, :temperature, :provider

  # `account:` opcional. Quando passado pela subclass (ex: Copilot, Assistant),
  # a resolução de modelo respeita `account.captain_<feature_key>_model`
  # (preferência setada no UI Configurações → Captain).
  #
  # Subclasses sem account em escopo continuam funcionando — caem no
  # InstallationConfig system-wide (comportamento legacy preservado).
  def initialize(account: nil)
    Llm::Config.initialize!
    @account = account
    setup_model
    setup_provider
    setup_temperature
  end

  def chat(model: @model, temperature: @temperature)
    # `provider:` explícito evita ambiguidade quando o mesmo model_id existe em
    # mais de um provider (ex: 'deepseek-v4-flash' direto vs OpenRouter wrapper).
    RubyLLM.chat(model: model, provider: @provider).with_temperature(temperature)
  end

  # Override em subclasses pra mapear pra entrada do config/llm.yml.
  # `nil` = sem mapping (cai no InstallationConfig system-wide).
  def feature_key
    nil
  end

  private

  # Strips markdown code fences (```json ... ``` or ``` ... ```) that some
  # LLM providers/gateways wrap around JSON responses despite response_format hints.
  def sanitize_json_response(response)
    return response if response.nil?

    response.strip.sub(/\A```(?:\w*)\s*\n?/, '').sub(/\n?\s*```\s*\z/, '').strip
  end

  # Cascata de resolução do modelo:
  #   1. preferência da account (UI Configurações → Captain) — só se feature
  #      declarada no llm.yml e account em escopo
  #   2. InstallationConfig system-wide CAPTAIN_OPEN_AI_MODEL (legacy)
  #   3. DEFAULT_MODEL global
  def setup_model
    feature = feature_key.to_s
    account_pref = if @account && feature.present? && Llm::Models.feature_keys.include?(feature)
                     @account.public_send("captain_#{feature}_model")
                   end
    system_pref = InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value
    @model = (account_pref.presence || system_pref.presence || DEFAULT_MODEL).to_s
  end

  def setup_provider
    @provider = Llm::Config.provider_for(@model)
  end

  def setup_temperature
    @temperature = DEFAULT_TEMPERATURE
  end
end
