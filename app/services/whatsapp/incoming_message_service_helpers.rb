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

  # Adalink: rede de segurança do referral (clique para o WhatsApp) contra
  # erro de DADO do Postgres — SQLSTATE classe 22 (PG::DataException), que
  # cobre byte NUL (PG::UntranslatableCharacter) e número fora do intervalo
  # do tipo numeric (PG::NumericValueOutOfRange; ActiveRecord::RangeError é
  # só o wrapper do Rails para isso, subclasse de StatementInvalid — um
  # rescue de StatementInvalid já cobre os dois). Como a trava de
  # duplicidade (Redis, 1 dia) já foi adquirida antes da transação, a
  # mensagem some para sempre se a gravação falhar; por isso refazemos uma
  # vez sem o referral. A checagem de e.cause.is_a?(PG::DataException) é
  # deliberada: timeout, deadlock ou conexão caída NÃO são erro de dado —
  # refazer sem o referral apagaria a origem do anúncio para um erro sem
  # relação com ele. Esses casos (e StatementInvalid sem referral) sobem.
  def persist_conversation_and_messages
    save_conversation_and_messages!
  rescue ActiveRecord::StatementInvalid => e
    referral = referral_params(messages_data.first)
    raise if @discard_referral || !e.cause.is_a?(PG::DataException) || referral.blank?

    Rails.logger.error "Whatsapp: failed (#{e.cause.class}), retrying without referral source_id=#{referral['source_id'].inspect}"
    @discard_referral = true
    save_conversation_and_messages!
  ensure
    @discard_referral = false
  end

  def save_conversation_and_messages!
    ActiveRecord::Base.transaction do
      set_conversation
      create_messages
    end
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
    return nil unless referral.is_a?(Hash)

    strip_nul_bytes(referral)
  end

  # Adalink: o Postgres recusa INSERT em coluna text/jsonb cujo valor (ou
  # CHAVE — jsonb não distingue) contenha o byte NUL (\u0000):
  # PG::UntranslatableCharacter. Isso derruba a transação de gravação da
  # mensagem/conversa. A 1ª tentativa fica registrada como erro (job falho,
  # visível nos logs); a trava de duplicidade (Redis, 1 dia) já foi
  # adquirida antes da transação começar, então qualquer reentrega
  # SEGUINTE do mesmo evento (pela Meta ou por um retry do Sidekiq) é
  # descartada em silêncio pela trava, sem nova tentativa de gravação — a
  # mensagem nunca chega a ser salva. Limpamos o NUL de chaves e valores,
  # em todos os níveis, em vez de descartar o referral inteiro, para não
  # jogar fora dados válidos (ctwa_clid, source_id etc.) por causa de 1 campo.
  #
  # Colisão de chaves após a limpeza (ex.: "a\u0000" e "a" viram a mesma
  # chave "a") é resolvida de forma determinística: como Ruby preserva a
  # ordem de inserção do Hash, each_with_object processa as chaves na
  # ordem em que aparecem no payload original, e a última a ser escrita
  # vence — mesma regra que um Hash literal com chaves duplicadas.
  def strip_nul_bytes(value)
    case value
    when String
      value.delete("\u0000")
    when Hash
      value.each_with_object({}) { |(k, v), h| h[k.to_s.delete("\u0000")] = strip_nul_bytes(v) }
    when Array
      value.map { |v| strip_nul_bytes(v) }
    else
      value
    end
  end

  # Adalink: grava o referral (anúncio de origem) inteiro nos
  # additional_attributes da mensagem que o carrega. @discard_referral é
  # ligado pela rede de segurança de persist_conversation_and_messages
  # (incoming_message_base_service.rb) quando a 1ª tentativa de gravação
  # falhou com um erro de dado do Postgres: nesse caso a 2ª tentativa grava
  # a mensagem sem o referral, em vez de tentar de novo com o mesmo valor
  # problemático.
  def referral_additional_attrs(message)
    return {} if @discard_referral

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
