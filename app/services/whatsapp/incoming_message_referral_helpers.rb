module Whatsapp::IncomingMessageReferralHelpers
  # Adalink: rede de segurança do referral (clique para o WhatsApp) contra
  # erro de DADO do Postgres — SQLSTATE classe 22 (PG::DataException), que
  # cobre byte NUL (PG::UntranslatableCharacter) e número fora do intervalo
  # do tipo numeric (PG::NumericValueOutOfRange; ActiveRecord::RangeError é
  # só o wrapper do Rails para isso, subclasse de StatementInvalid — um
  # rescue de StatementInvalid já cobre os dois). Como a trava de
  # duplicidade (Redis, 1 dia) já foi adquirida antes da transação, sem
  # essa rede a mensagem sumiria para sempre se a gravação falhasse (a 1ª
  # tentativa falharia e toda reentrega seguinte seria descartada em
  # silêncio pela trava) — por isso refazemos uma vez sem o referral. A
  # checagem de e.cause.is_a?(PG::DataException) é deliberada: timeout,
  # deadlock ou conexão caída NÃO são erro de dado — refazer sem o
  # referral apagaria a origem do anúncio para um erro sem relação com
  # ele. Esses casos (e StatementInvalid sem referral) sobem intactos.
  # A 2ª chamada de save_conversation_and_messages! (linha abaixo) roda
  # dentro deste mesmo rescue: se ela falhar de novo, a exceção propaga
  # direto para fora do método, sem re-executar este rescue. Por isso
  # @discard_referral nunca está true quando chegamos aqui — não há guard
  # contra reentrância porque não existe reentrância possível.
  def persist_conversation_and_messages
    save_conversation_and_messages!
  rescue ActiveRecord::StatementInvalid => e
    referral = referral_params(messages_data.first)
    raise if !e.cause.is_a?(PG::DataException) || referral.blank?

    Rails.logger.error "Whatsapp: failed (#{e.cause.class}) persisting message " \
                       "wamid=#{messages_data.first[:id].inspect} with referral " \
                       "source_id=#{referral['source_id'].inspect}, retrying without it"
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
  # PG::UntranslatableCharacter. Sem esta limpeza, um referral com esse byte
  # derrubaria a transação de gravação da mensagem/conversa (capturado pela
  # rede de segurança em persist_conversation_and_messages, mas só depois
  # de uma tentativa perdida). Limpamos o NUL de chaves e valores, em todos
  # os níveis, em vez de descartar o referral inteiro, para não jogar fora
  # dados válidos (ctwa_clid, source_id etc.) por causa de 1 campo.
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
  # ligado por persist_conversation_and_messages, neste mesmo módulo,
  # quando a 1ª tentativa de gravação falhou com um erro de dado do
  # Postgres: nesse caso a 2ª tentativa grava a mensagem sem o referral,
  # em vez de tentar de novo com o mesmo valor problemático.
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
end
