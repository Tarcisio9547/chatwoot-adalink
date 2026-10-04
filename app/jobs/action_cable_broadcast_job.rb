class ActionCableBroadcastJob < ApplicationJob
  queue_as :critical
  include Events::Types

  CONVERSATION_UPDATE_EVENTS = [
    CONVERSATION_READ,
    CONVERSATION_UPDATED,
    TEAM_CHANGED,
    ASSIGNEE_CHANGED,
    CONVERSATION_STATUS_CHANGED
  ].freeze

  def perform(members, event_name, data)
    return if members.blank?

    broadcast_data = prepare_broadcast_data(event_name, data)
    broadcast_to_members(members, event_name, broadcast_data)
  end

  private

  # Ensures that only the latest available data is sent to prevent UI issues
  # caused by out-of-order events during high-traffic periods. This prevents
  # the conversation job from processing outdated data.
  def prepare_broadcast_data(event_name, data)
    return data unless CONVERSATION_UPDATE_EVENTS.include?(event_name)

    account = Account.find(data[:account_id])
    conversation = account.conversations.find_by!(display_id: data[:id])
    conversation_payload(conversation, data)
  end

  # Adalink: o payload de conversa remontado aqui é o comum (o mesmo que chega ao contato).
  # participant_ids só entra se o listener o pediu (payload de agente, com a chave) e é lido de
  # novo agora, não do enfileiramento. Quem decide quem o recebe é broadcast_to_members.
  def conversation_payload(conversation, data)
    payload = conversation.push_event_data.merge(account_id: data[:account_id])
    return payload unless data.key?(:participant_ids)

    payload.merge(participant_ids: conversation.conversation_participants.pluck(:user_id))
  end

  # participant_ids é dado de agente: o contato (widget) e qualquer token que não seja de usuário
  # recebem o mesmo payload sem a chave. Uma consulta (índice único do pubsub_token) por job, e só
  # quando o payload traz o campo.
  def broadcast_to_members(members, event_name, broadcast_data)
    agent_tokens = agent_tokens_for(members, broadcast_data)
    members.each do |member|
      data = broadcast_data.key?(:participant_ids) && agent_tokens.exclude?(member) ? broadcast_data.except(:participant_ids) : broadcast_data
      ActionCable.server.broadcast(
        member,
        {
          event: event_name,
          data: data
        }
      )
    end
  end

  def agent_tokens_for(members, broadcast_data)
    return [] unless broadcast_data.key?(:participant_ids)

    User.where(pubsub_token: members).pluck(:pubsub_token)
  end
end

ActionCableBroadcastJob.prepend_mod_with('ActionCableBroadcastJob')
