# Leitura do corpo bruto de um webhook da Meta. O que foi assinado é o corpo bruto, então é dele (e só dele)
# que o controller tira a decisão e o que enfileira: query string e parâmetros embrulhados do Rails não entram.
module MetaWebhookPayloadConcern
  private

  def meta_request_body
    @meta_request_body ||= request.raw_post
  end

  # Corpo da requisição como Hash com acesso indiferente, lido SÓ do corpo bruto (a mesma coisa que foi
  # assinada). Nada da query string nem dos parâmetros embrulhados do Rails entra aqui. Devolve nil quando o
  # corpo não é JSON ou não é um objeto JSON.
  def meta_webhook_payload
    return @meta_webhook_payload if defined?(@meta_webhook_payload)

    parsed = JSON.parse(meta_request_body)
    @meta_webhook_payload = parsed.is_a?(Hash) ? parsed.with_indifferent_access : nil
  rescue JSON::ParserError, EncodingError
    @meta_webhook_payload = nil
  end

  # Navega num payload qualquer sem estourar quando o formato não é o esperado (string no lugar de objeto,
  # objeto no lugar de lista etc.): devolve nil no primeiro passo que não bater.
  def meta_payload_dig(object, *path)
    path.reduce(object) do |current, key|
      case current
      when Hash then current[key]
      when Array then key.is_a?(Integer) ? current[key] : nil
      end
    end
  end
end
