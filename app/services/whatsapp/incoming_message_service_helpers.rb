module Whatsapp::IncomingMessageServiceHelpers
  def download_attachment_file(attachment_payload)
    Down.download(inbox.channel.media_url(attachment_payload[:id]), headers: inbox.channel.api_headers)
  end

  def conversation_params
    {
      account_id: @inbox.account_id,
      inbox_id: @inbox.id,
      contact_id: @contact.id,
      contact_inbox_id: @contact_inbox.id,
      additional_attributes: new_conversation_additional_attrs
    }
  end

  def processed_params
    @processed_params ||= params
  end

  def account
    @account ||= inbox.account
  end

  def message_type
    messages_data.first[:type]
  end

  def message_content(message)
    # TODO: map interactive messages back to button messages in chatwoot
    message.dig(:text, :body) ||
      message.dig(:button, :text) ||
      message.dig(:interactive, :button_reply, :title) ||
      message.dig(:interactive, :list_reply, :title) ||
      message.dig(:name, :formatted_name)
  end

  def file_content_type(file_type)
    return :image if %w[image sticker].include?(file_type)
    return :audio if %w[audio voice].include?(file_type)
    return :video if ['video'].include?(file_type)
    return :location if ['location'].include?(file_type)
    return :contact if ['contacts'].include?(file_type)

    :file
  end

  def unprocessable_message_type?(message_type)
    %w[reaction ephemeral unsupported request_welcome].include?(message_type)
  end

  def processed_waid(waid)
    Whatsapp::PhoneNumberNormalizationService.new(inbox).normalize_and_find_contact_by_provider(waid, :cloud)
  end

  def error_webhook_event?(message)
    message.key?('errors')
  end

  def log_error(message)
    Rails.logger.warn "Whatsapp Error: #{message['errors'][0]['title']} - contact: #{message['from']}"
  end

  def process_in_reply_to(message)
    @in_reply_to_external_id = message['context']&.[]('id')
  end

  # Adalink: clique para o WhatsApp — anúncio de origem (referral) da Meta.
  # Presente em qualquer caixa Channel::Whatsapp (provider whatsapp_cloud ou
  # 360dialog — ambos passam por este mesmo serviço base); o WhatsApp pessoal
  # (Evolution) é uma caixa Channel::Api e nunca chega a este código.
  # Só aceitamos Hash: um valor malformado (string, array, nil) nunca pode
  # derrubar a gravação da mensagem — nesse caso o referral é descartado.
  # https://developers.facebook.com/docs/whatsapp/cloud-api/webhooks/payload-examples#referral-messages
  def referral_params(message)
    referral = message['referral']
    referral.is_a?(Hash) ? referral : nil
  end

  # Adalink: grava o referral (anúncio de origem) inteiro nos
  # additional_attributes da mensagem que o carrega.
  def referral_additional_attrs(message)
    referral = referral_params(message)
    referral.present? ? { referral: referral } : {}
  end

  # Adalink: a conversa guarda o referral da mensagem que a CRIOU. Cliques
  # seguintes (outro referral numa conversa já existente) ficam só na
  # mensagem correspondente — não sobrescrevem o referral original da
  # conversa. Por isso conversation_params só olha messages_data.first
  # (a mensagem raiz do payload, a única que pode criar a conversa).
  def new_conversation_additional_attrs
    referral_additional_attrs(messages_data.first)
  end

  def find_message_by_source_id(source_id)
    return unless source_id

    @message = Message.find_by(source_id: source_id)
  end

  def lock_message_source_id!
    return false if messages_data.blank?

    Whatsapp::MessageDedupLock.new(messages_data.first[:id]).acquire!
  end
end
