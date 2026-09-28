module Whatsapp::IncomingMessageServiceHelpers
  def download_attachment_file(attachment_payload)
    Down.download(inbox.channel.media_url(attachment_payload[:id]), headers: inbox.channel.api_headers)
  end

  def conversation_params
    {
      account_id: @inbox.account_id,
      inbox_id: @inbox.id,
      contact_id: @contact.id,
      contact_inbox_id: @contact_inbox.id
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
  # Só o provider whatsapp_cloud manda esse objeto; para os demais providers
  # (ex: 360dialog/WhatsApp pessoal) o campo simplesmente não existe no payload.
  # https://developers.facebook.com/docs/whatsapp/cloud-api/webhooks/payload-examples#referral-messages
  def referral_params(message)
    message['referral']
  end

  # Adalink: grava o referral (anúncio de origem) inteiro nos
  # additional_attributes da mensagem e, se a conversa acabou de nascer
  # dessa mensagem, também nos additional_attributes dela.
  def message_additional_attrs(message)
    referral = referral_params(message)
    return {} if referral.blank?

    attach_referral_to_conversation(referral)
    { referral: referral }
  end

  # Adalink: quando a conversa nasce de uma mensagem com referral, guarda o
  # objeto inteiro nos additional_attributes da conversa para ele aparecer
  # no payload do webhook message_created. Mensagens seguintes na mesma
  # conversa não sobrescrevem o referral original.
  def attach_referral_to_conversation(referral)
    return unless @conversation_created_now

    @conversation.additional_attributes = @conversation.additional_attributes.merge('referral' => referral)
    @conversation.save!
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
