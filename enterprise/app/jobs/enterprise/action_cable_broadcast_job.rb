# Os destinatários (tokens) do broadcast são calculados no disparo do evento,
# mas o payload é relido da conversa quando o job executa. Se a fila atrasar e
# a conversa trocar de responsável (A->B) com mensagem nova de B nesse
# intervalo, A receberia conteúdo posterior à troca. Na caixa WhatsApp a
# execução refiltra os destinatários pelo papel: quem perdeu acesso só recebe
# assignee.changed, sem `messages` (o bastante pra tela tirar a conversa da
# lista); nos demais eventos de conversa ele sai da lista. Outras caixas e
# eventos que não são de conversa seguem o upstream, sem consulta extra.
#
# Limite conhecido: quem perdeu acesso e recebe o assignee.changed fica só sem
# `messages`; os metadados da conversa (contato, etiquetas, novo responsável)
# vão no payload, porque a tela precisa deles pra tirar a conversa da lista.
module Enterprise::ActionCableBroadcastJob
  include Events::Types

  def perform(members, event_name, data)
    return super if members.blank? || !whatsapp_conversation_event?(event_name, data)

    conversation = Conversation.find_by(account_id: data[:account_id], display_id: data[:id])
    return super if conversation.nil?

    partition = partition_members_by_visibility(members, conversation)
    return super if partition.nil?

    broadcast_filtered(partition, conversation, event_name, data)
  end

  private

  def whatsapp_conversation_event?(event_name, data)
    return false unless ActionCableBroadcastJob::CONVERSATION_UPDATE_EVENTS.include?(event_name)
    return false if data[:account_id].blank? || data[:id].blank?

    # O payload de conversa sempre traz :channel (Conversation#push_event_data).
    data[:channel] == Conversations::RoleVisibility::WHATSAPP_CHANNEL_TYPE
  end

  # Separa members (tokens) em quem continua vendo a conversa e quem perdeu o
  # acesso. Token que não é de User (contato do widget) continua vendo.
  def partition_members_by_visibility(members, conversation)
    users_by_token = User.where(pubsub_token: members).index_by(&:pubsub_token)
    return nil if users_by_token.empty?

    lost_access_tokens = tokens_without_access(users_by_token, conversation)
    still_visible, lost_access = members.partition { |token| lost_access_tokens.exclude?(token) }

    { still_visible: still_visible, lost_access: lost_access }
  end

  def tokens_without_access(users_by_token, conversation)
    visible_ids = Conversations::RoleVisibility.visible_members(conversation, users_by_token.values).to_set(&:id)
    users_by_token.reject { |_token, user| visible_ids.include?(user.id) }.keys
  end

  # Reaproveita a conversa já carregada (o upstream a buscaria de novo em
  # prepare_broadcast_data) e monta o mesmo payload.
  def broadcast_filtered(partition, conversation, event_name, data)
    still_visible = partition[:still_visible]
    lost_access = partition[:lost_access]
    full_data = conversation.push_event_data.merge(account_id: data[:account_id])

    broadcast_to_members(still_visible, event_name, full_data) if still_visible.any?
    return if lost_access.empty? || event_name != ASSIGNEE_CHANGED

    broadcast_to_members(lost_access, event_name, full_data.except(:messages))
  end
end
