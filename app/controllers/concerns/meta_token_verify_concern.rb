# services from Meta (Prev: Facebook) needs a token verification step for webhook subscriptions,
# This concern handles the token verification step.
#
# Também confere o cabeçalho X-Hub-Signature-256 (HMAC SHA256 do corpo bruto, assinado com o App Secret
# do app da Meta) nos endpoints POST dos webhooks, para que só a Meta consiga injetar eventos.
#
# Deploy seguro: se NÃO existe nenhum app secret disponível (nem no canal nem global) não há com o que
# comparar, então a requisição é aceita (como era antes desta checagem) e um aviso é registrado no log,
# uma vez por requisição. Assim que um segredo é configurado, a assinatura passa a ser obrigatória.

module MetaTokenVerifyConcern
  CHANNEL_APP_SECRET_KEYS = %w[app_secret app_secret_key client_secret api_secret].freeze
  META_SIGNATURE_HEADER = 'X-Hub-Signature-256'.freeze
  META_SIGNATURE_PREFIX = 'sha256='.freeze
  META_WEBHOOK_LOG_TAG = '[meta-webhook]'.freeze

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
    return log_meta_signature_not_verifiable if secrets.blank?
    return if valid_meta_signature?(secrets)

    log_meta_signature_rejected
    head :unauthorized
  end

  def valid_meta_signature?(secrets)
    signature = request.headers[META_SIGNATURE_HEADER]
    return false unless signature&.start_with?(META_SIGNATURE_PREFIX)

    secrets.any? do |secret|
      expected_signature = "#{META_SIGNATURE_PREFIX}#{OpenSSL::HMAC.hexdigest('SHA256', secret, meta_request_body)}"
      ActiveSupport::SecurityUtils.secure_compare(expected_signature, signature)
    end
  end

  def meta_request_body
    @meta_request_body ||= request.raw_post
  end

  # Segredos aceitos na requisição atual. Os controllers devolvem os segredos do canal e só recorrem aos
  # globais quando o canal não tem nenhum (ver #meta_secrets_with_channel_priority).
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

  # O segredo do canal tem prioridade: se o canal tem segredo próprio, só ele é aceito.
  # Os globais só valem para canais sem segredo próprio.
  def meta_secrets_with_channel_priority(channel_secrets, global_secrets)
    channel_secrets.compact_blank.presence || global_secrets.compact_blank
  end

  # O GlobalConfigService só lê o ENV quando NÃO existe linha em installation_configs. O ConfigLoader semeia
  # uma linha sem valor para as chaves *_APP_SECRET, então o ENV (ex.: variável do Railway) é lido direto como
  # fallback. O valor salvo no InstallationConfig (Super Admin) continua com precedência sobre o ENV.
  def global_meta_app_secret(config_name)
    GlobalConfigService.load(config_name, nil).to_s.strip.presence || ENV[config_name].to_s.strip.presence
  end

  def channel_meta_app_secrets(channel)
    return [] if channel.blank?

    secrets = []
    secrets << channel.app_secret if channel.respond_to?(:app_secret)
    secrets.concat(provider_config_meta_app_secrets(channel))
    secrets.compact_blank.uniq
  end

  def provider_config_meta_app_secrets(channel)
    return [] unless channel.respond_to?(:provider_config)

    provider_config = channel.provider_config.to_h.with_indifferent_access
    CHANNEL_APP_SECRET_KEYS.filter_map { |key| provider_config[key].presence }
  end

  def log_meta_signature_not_verifiable
    Rails.logger.warn(
      "#{META_WEBHOOK_LOG_TAG} #{self.class.name}: assinatura #{META_SIGNATURE_HEADER} NAO conferida, " \
      "nenhum app secret configurado (canal ou global). Configure #{meta_global_secret_config_names.join(' ou ')} " \
      'para exigir a assinatura. Requisicao aceita sem validar.'
    )
  end

  def log_meta_signature_rejected
    reason = request.headers[META_SIGNATURE_HEADER].present? ? 'invalida' : 'ausente'
    Rails.logger.warn(
      "#{META_WEBHOOK_LOG_TAG} #{self.class.name}: requisicao rejeitada (401), assinatura #{META_SIGNATURE_HEADER} #{reason}. " \
      "path=#{request.path}"
    )
  end

  def valid_token?(_token)
    raise 'Overwrite this method your controller'
  end
end
