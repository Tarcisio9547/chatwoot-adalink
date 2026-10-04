# services from Meta (Prev: Facebook) needs a token verification step for webhook subscriptions,
# This concern handles the token verification step.
#
# Também confere o cabeçalho X-Hub-Signature-256 (HMAC SHA256 do corpo bruto, assinado com o App Secret
# do app da Meta) nos endpoints POST dos webhooks, para que só a Meta consiga injetar eventos.
#
# Deploy seguro: se NÃO existe nenhum app secret disponível não há com o que comparar, então a requisição
# é aceita (como era antes desta checagem) e um aviso é registrado no log, no máximo 1 por hora por processo
# e por controller (com a contagem de requisições aceitas desde o último aviso). Assim que um segredo é
# configurado, a assinatura passa a ser obrigatória. Para recusar também quando não há segredo, ligue a
# variável de ambiente META_WEBHOOK_REQUIRE_SIGNATURE=true.
#
# Segredo por canal (provider_config) é suportado, mas NÃO grave o segredo do app da Meta no provider_config
# de uma caixa: o administrador da empresa enxerga esse campo. Prefira o segredo global (InstallationConfig/ENV).

module MetaTokenVerifyConcern
  include MetaWebhookPayloadConcern

  CHANNEL_APP_SECRET_KEYS = %w[app_secret app_secret_key client_secret api_secret].freeze
  META_SIGNATURE_HEADER = 'X-Hub-Signature-256'.freeze
  META_SIGNATURE_PREFIX = 'sha256='.freeze
  META_WEBHOOK_LOG_TAG = '[meta-webhook]'.freeze
  REQUIRE_SIGNATURE_ENV = 'META_WEBHOOK_REQUIRE_SIGNATURE'.freeze
  REQUIRE_SIGNATURE_TRUE_VALUES = %w[true 1 yes on].freeze

  def verify
    service = is_a?(Webhooks::WhatsappController) ? 'whatsapp' : 'instagram'
    if valid_token?(params['hub.verify_token'])
      Rails.logger.info("#{service.capitalize} webhook verified")
      render json: params['hub.challenge']
    else
      render status: :unauthorized, json: { error: 'Error; wrong verify token' }
    end
  end

  private

  def verify_meta_signature!
    return unless meta_signature_verification_required?

    secrets = meta_app_secrets
    return verify_meta_request_without_secret if secrets.blank?
    return if valid_meta_signature?(secrets)

    reject_meta_request(request.headers[META_SIGNATURE_HEADER].present? ? 'invalida' : 'ausente')
  end

  # Sem nenhum segredo: aceita e avisa (com throttle), a menos que META_WEBHOOK_REQUIRE_SIGNATURE esteja ligada.
  def verify_meta_request_without_secret
    if meta_signature_required_without_secret?
      return reject_meta_request(
        "nenhum app secret configurado e #{REQUIRE_SIGNATURE_ENV} ativa (configure #{meta_global_secret_config_names.join(' ou ')})",
        include_header_state: false
      )
    end

    log_meta_signature_not_verifiable
  end

  def valid_meta_signature?(secrets)
    signature = request.headers[META_SIGNATURE_HEADER]
    return false unless signature&.start_with?(META_SIGNATURE_PREFIX)

    secrets.any? do |secret|
      expected_signature = "#{META_SIGNATURE_PREFIX}#{OpenSSL::HMAC.hexdigest('SHA256', secret, meta_request_body)}"
      ActiveSupport::SecurityUtils.secure_compare(expected_signature, signature)
    end
  end

  # Segredos aceitos na requisição atual. Os controllers devolvem os segredos do canal (se houver) e só
  # recorrem aos globais quando o canal não tem nenhum (ver #meta_secrets_with_channel_priority).
  def meta_app_secrets
    raise 'Overwrite this method in your controller'
  end

  # Nomes das configs globais (InstallationConfig / ENV) citados no log para quem for configurar.
  def meta_global_secret_config_names
    raise 'Overwrite this method in your controller'
  end

  def meta_signature_verification_required?
    true
  end

  # META_WEBHOOK_REQUIRE_SIGNATURE=true recusa (401) quando não existe nenhum segredo. Padrão: desligada.
  def meta_signature_required_without_secret?
    REQUIRE_SIGNATURE_TRUE_VALUES.include?(ENV.fetch(REQUIRE_SIGNATURE_ENV, '').to_s.strip.downcase)
  end

  # O segredo do canal tem prioridade: se o canal tem segredo próprio, só ele é aceito.
  # Os globais só valem para canais sem segredo próprio.
  def meta_secrets_with_channel_priority(channel_secrets, global_secrets)
    channel_secrets.compact_blank.presence || global_secrets.compact_blank
  end

  # O GlobalConfigService só lê o ENV quando NÃO existe linha em installation_configs. O ConfigLoader semeia
  # uma linha sem valor para as chaves *_APP_SECRET, então o ENV (ex.: variável do Railway) é lido direto como
  # fallback. O valor salvo no InstallationConfig (Super Admin) continua com precedência sobre o ENV.
  def global_meta_app_secret(config_name)
    clean_meta_secret(GlobalConfigService.load(config_name, nil)) || clean_meta_secret(ENV.fetch(config_name, nil))
  end

  def clean_meta_secret(value)
    value.to_s.strip.presence
  end

  def channel_meta_app_secrets(channel)
    return [] if channel.blank?

    secrets = []
    secrets << channel.app_secret if channel.respond_to?(:app_secret)
    secrets.concat(provider_config_meta_app_secrets(channel))
    secrets.filter_map { |secret| clean_meta_secret(secret) }.uniq
  end

  def provider_config_meta_app_secrets(channel)
    return [] unless channel.respond_to?(:provider_config)

    provider_config = channel.provider_config.to_h.with_indifferent_access
    CHANNEL_APP_SECRET_KEYS.filter_map { |key| clean_meta_secret(provider_config[key]) }
  end

  def log_meta_signature_not_verifiable
    should_warn, accepted = MetaWebhook::UnverifiedWarningThrottle.register(self.class.name)
    return unless should_warn

    Rails.logger.warn(
      "#{META_WEBHOOK_LOG_TAG} #{self.class.name}: assinatura #{META_SIGNATURE_HEADER} NAO conferida, " \
      "nenhum app secret configurado. Configure #{meta_global_secret_config_names.join(' ou ')} " \
      "para exigir a assinatura (ou ligue #{REQUIRE_SIGNATURE_ENV}=true para recusar sem segredo). " \
      "Requisicoes aceitas sem conferir desde o ultimo aviso: #{accepted}. Proximo aviso em ate 1 hora."
    )
  end

  def reject_meta_request(reason, include_header_state: true)
    detail = include_header_state ? "assinatura #{META_SIGNATURE_HEADER} #{reason}" : reason
    Rails.logger.warn("#{META_WEBHOOK_LOG_TAG} #{self.class.name}: requisicao rejeitada (401), #{detail}. path=#{request.path}")
    head :unauthorized
  end

  def valid_token?(_token)
    raise 'Overwrite this method your controller'
  end
end
