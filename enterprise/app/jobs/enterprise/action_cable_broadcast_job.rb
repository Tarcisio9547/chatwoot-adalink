# Adalink: correção do juiz cego (rodada 3, item 2, BAIXA/MÉDIA) - evento
# atrasado entrega a quem perdeu a conversa dados de DEPOIS da troca.
#
# ActionCableBroadcastJob calcula os destinatários (tokens) no DISPARO do
# evento (ainda síncrono, RoleVisibility já filtra corretamente quem pode
# ver NAQUELE momento), mas o payload (via prepare_broadcast_data) é
# recarregado da conversa no momento da EXECUÇÃO do job — que pode atrasar
# (fila cheia, worker lento). Se a conversa for reatribuída de A para B
# nesse intervalo, e B mandar uma mensagem nova antes do job de A executar,
# A recebe (quando o job finalmente roda) o push_event_data ATUAL da
# conversa — que já inclui a mensagem nova de B, via push_data[:messages].
#
# Correção, só em Channel::Whatsapp: na execução do job (não no disparo),
# reavalia quem dos destinatários (tokens de User, não de contato) ainda
# pode ver a conversa pela regra de papel. Quem perdeu o acesso:
#   - no evento assignee.changed, continua recebendo (a tela dele precisa
#     do evento pra tirar a conversa da lista), mas sem `messages`/última
#     mensagem no payload;
#   - em qualquer outro evento (message.created, conversation.updated etc.),
#     é removido da lista de destinatários — não recebe nada.
# Outras caixas ficam idênticas ao upstream.
module Enterprise::ActionCableBroadcastJob
  include Events::Types

  def perform(members, event_name, data)
    return super unless whatsapp_conversation_event?(event_name, data)

    conversation = conversation_for(data)
    return super if conversation.blank?

    members_by_recipient = partition_members_by_visibility(members, conversation)
    return super if members_by_recipient.nil?

    broadcast_filtered(members_by_recipient, event_name, data)
  end

  private

  def whatsapp_conversation_event?(event_name, data)
    ActionCableBroadcastJob::CONVERSATION_UPDATE_EVENTS.include?(event_name) && data[:account_id].present? && data[:id].present?
  end

  def conversation_for(data)
    account = Account.find_by(id: data[:account_id])
    return nil if account.blank?

    account.conversations.find_by(display_id: data[:id])
  end

  # Separa members (tokens) em quem continua vendo a conversa e quem
  # perdeu - só entre os tokens que correspondem a User (tokens de contato,
  # não resolvidos, ficam fora das duas listas e são tratados como
  # "continuam vendo", já que não são dados de agente).
  def partition_members_by_visibility(members, conversation)
    return nil unless conversation.inbox&.whatsapp?

    users_by_token = User.where(pubsub_token: members).index_by(&:pubsub_token)
    return nil if users_by_token.empty?

    visible_user_ids = Conversations::RoleVisibility.visible_members(conversation, users_by_token.values).map(&:id).to_set

    still_visible = []
    lost_access = []
    members.each do |token|
      user = users_by_token[token]
      if user.nil?
        still_visible << token
      elsif visible_user_ids.include?(user.id)
        still_visible << token
      else
        lost_access << token
      end
    end

    { still_visible: still_visible, lost_access: lost_access }
  end

  def broadcast_filtered(members_by_recipient, event_name, data)
    still_visible = members_by_recipient[:still_visible]
    lost_access = members_by_recipient[:lost_access]

    full_broadcast_data = prepare_broadcast_data(event_name, data)
    broadcast_to_members(still_visible, event_name, full_broadcast_data) if still_visible.any?

    return if lost_access.empty?
    return unless event_name == ASSIGNEE_CHANGED

    # Quem perdeu o acesso só recebe assignee.changed, e sem messages/última
    # mensagem - o suficiente pra tela tirar a conversa da lista, sem
    # vazar conteúdo posterior à troca.
    stripped_data = full_broadcast_data.is_a?(Hash) ? full_broadcast_data.except(:messages) : full_broadcast_data
    broadcast_to_members(lost_access, event_name, stripped_data)
  end
end
