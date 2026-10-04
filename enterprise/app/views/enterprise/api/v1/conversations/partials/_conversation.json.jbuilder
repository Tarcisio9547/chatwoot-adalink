# Adalink: quem participa da conversa. O filtro de visibilidade do navegador
# (applyRoleFilter) usa isto pra manter na lista a conversa em que o usuário é
# participante e não responsável. Também vai nos eventos ao vivo (EventDataPresenter).
json.participant_ids conversation.conversation_participants.map(&:user_id)

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
