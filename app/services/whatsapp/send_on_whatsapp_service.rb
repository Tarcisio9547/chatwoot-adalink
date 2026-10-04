class Whatsapp::SendOnWhatsappService < Base::SendOnChannelService
  CAROUSEL_NOT_SUPPORTED_ERROR = 'Modelo carrossel ainda não é suportado pelo Atendimento'.freeze

  private

  def channel_class
    Channel::Whatsapp
  end

  def perform_reply
    should_send_template_message = template_params.present? || !message.conversation.can_reply?
    if should_send_template_message
      send_template_message
    else
      send_session_message
    end
  end

  def send_template_message
    return fail_carousel_template if carousel_template?

    processor = Whatsapp::TemplateProcessorService.new(
      channel: channel,
      template_params: template_params,
      message: message
    )

    name, namespace, lang_code, processed_parameters = processor.call

    if name.blank?
      message.update!(status: :failed, external_error: 'Template not found or invalid template name')
      return
    end

    message_id = channel.send_template(message.conversation.contact_inbox.source_id, {
                                         name: name,
                                         namespace: namespace,
                                         lang_code: lang_code,
                                         parameters: processed_parameters
                                       }, message)
    message.update!(source_id: message_id) if message_id.present?
  end

  def send_session_message
    message_id = channel.send_message(message.conversation.contact_inbox.source_id, message)
    message.update!(source_id: message_id) if message_id.present?
  end

  def template_params
    message.additional_attributes && message.additional_attributes['template_params']
  end

  # Carrossel exige os cartões na chamada; sem isso a Meta responde #132012.
  # Falha aqui, com texto claro, em vez de gastar a chamada e mostrar erro cru.
  def fail_carousel_template
    message.update!(status: :failed, external_error: CAROUSEL_NOT_SUPPORTED_ERROR)
  end

  def carousel_template?
    return false if template_params.blank?

    Array(channel.message_templates).any? do |template|
      same_template?(template) && Array(template['components']).any? { |component| component['type']&.upcase == 'CAROUSEL' }
    end
  end

  def same_template?(template)
    template['name'] == template_params['name'] &&
      template['language']&.downcase == template_params['language']&.downcase
  end
end
