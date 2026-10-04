# Adalink: quem participa da conversa. O filtro de visibilidade do navegador (applyRoleFilter) usa
# isto pra manter na lista a conversa em que o usuário é participante e não responsável. Só vai a
# agentes: nas respostas autenticadas da API e nos eventos ao vivo de agente
# (Conversation#agent_push_event_data), nunca no contato nem nos webhooks. Usa os participantes já
# pré-carregados (ConversationFinder, FilterService, conversas do contato) para não gerar uma
# consulta por conversa; sem pré-carga, uma consulta só dos ids.
participants = conversation.conversation_participants
json.participant_ids(participants.loaded? ? participants.map(&:user_id) : participants.pluck(:user_id))

if conversation.account.feature_enabled?('sla')
  json.applied_sla do
    json.partial! 'api/v1/models/applied_sla', formats: [:json], resource: conversation.applied_sla if conversation.applied_sla.present?
  end
  json.sla_events do
    json.array! conversation.sla_events do |sla_event|
      json.partial! 'api/v1/models/sla_event', formats: [:json], sla_event: sla_event
    end
  end
end
