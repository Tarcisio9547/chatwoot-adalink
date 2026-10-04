class Webhooks::WhatsappController < ActionController::API
  include MetaTokenVerifyConcern

  before_action :verify_meta_signature!, only: :process_payload

  def process_payload
    return head :bad_request if meta_webhook_payload.nil?

    if inactive_whatsapp_number?
      Rails.logger.warn("Rejected webhook for inactive WhatsApp number: #{params[:phone_number]}")
      render json: { error: 'Inactive WhatsApp number' }, status: :unprocessable_entity
      return
    end

    Webhooks::WhatsappEventsJob.perform_later(job_params)
    head :ok
  end

  private

  # O job recebe só o corpo assinado (Hash com acesso indiferente, como antes) mais o phone_number da rota.
  # Query string e demais parâmetros do Rails não chegam ao job, então o canal que o job resolve é o mesmo
  # que a assinatura acabou de validar.
  def job_params
    meta_webhook_payload.merge(phone_number: params[:phone_number])
  end

  def valid_token?(token)
    channel = Channel::Whatsapp.find_by(phone_number: params[:phone_number])
    whatsapp_webhook_verify_token = channel.provider_config['webhook_verify_token'] if channel.present?
    token == whatsapp_webhook_verify_token if whatsapp_webhook_verify_token.present?
  end

  # O segredo do canal (provider_config) tem prioridade; o global (WHATSAPP_APP_SECRET) vale para as caixas
  # que não têm segredo próprio, como as caixas Cloud criadas manualmente.
  def meta_app_secrets
    meta_secrets_with_channel_priority(
      channel_meta_app_secrets(whatsapp_channel),
      [global_meta_app_secret('WHATSAPP_APP_SECRET')]
    )
  end

  def meta_global_secret_config_names
    ['WHATSAPP_APP_SECRET']
  end

  def whatsapp_channel
    @whatsapp_channel ||= whatsapp_business_payload_channel || Channel::Whatsapp.find_by(phone_number: params[:phone_number])
  end

  # 360dialog (provider 'default') não assina os webhooks, então não há o que conferir.
  # Para o WhatsApp Cloud a assinatura é sempre exigida quando existe algum segredo (canal ou global);
  # sem nenhum segredo o concern aceita e avisa no log. Sem canal identificado, vale a mesma regra.
  def meta_signature_verification_required?
    whatsapp_channel.blank? || whatsapp_channel.provider == 'whatsapp_cloud'
  end

  # Mesma resolução do Webhooks::WhatsappEventsJob (número do payload + phone_number_id), lida só do corpo e
  # sem estourar com formatos inesperados, porque isto roda ANTES de a assinatura ser conferida.
  def whatsapp_business_payload_channel
    return unless meta_webhook_payload&.dig('object') == 'whatsapp_business_account'

    metadata = meta_payload_dig(meta_webhook_payload, 'entry', 0, 'changes', 0, 'value', 'metadata')
    return unless metadata.is_a?(Hash)

    phone_number = normalized_phone_number(metadata['display_phone_number'])
    phone_number_id = metadata['phone_number_id']
    channel = Channel::Whatsapp.find_by(phone_number: phone_number)

    return channel if channel && channel.provider_config['phone_number_id'] == phone_number_id
  end

  def normalized_phone_number(phone_number)
    return if phone_number.blank?

    phone_number = phone_number.to_s
    phone_number.start_with?('+') ? phone_number : "+#{phone_number}"
  end

  def inactive_whatsapp_number?
    phone_number = params[:phone_number]
    return false if phone_number.blank?

    inactive_numbers = GlobalConfig.get_value('INACTIVE_WHATSAPP_NUMBERS').to_s
    return false if inactive_numbers.blank?

    inactive_numbers_array = inactive_numbers.split(',').map(&:strip)
    inactive_numbers_array.include?(phone_number)
  end
end
