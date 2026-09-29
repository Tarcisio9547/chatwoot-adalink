# Adalink: guarda o anúncio de origem (clique para o WhatsApp) que a Meta envia
# em `referral`, na mensagem e na conversa que ela cria.
# https://developers.facebook.com/docs/whatsapp/cloud-api/webhooks/payload-examples#referral-messages
module Whatsapp::IncomingMessageReferralHelpers
  def referral_additional_attrs(message)
    referral = message['referral']
    return {} unless referral.is_a?(Hash)

    { referral: strip_nul_bytes(referral) }
  end

  private

  # O Postgres recusa o byte NUL em jsonb; sem isso a mensagem inteira falharia ao gravar.
  def strip_nul_bytes(value)
    case value
    when String then value.delete("\u0000")
    when Hash then value.to_h { |k, v| [k.to_s.delete("\u0000"), strip_nul_bytes(v)] }
    when Array then value.map { |v| strip_nul_bytes(v) }
    else value
    end
  end
end
