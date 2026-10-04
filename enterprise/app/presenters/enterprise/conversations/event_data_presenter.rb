module Enterprise::Conversations::EventDataPresenter
  # Adalink: participant_ids vai em todo evento ao vivo (uma consulta indexada por
  # evento, não por destinatário) pra tela saber quem participa da conversa. O filtro
  # de visibilidade do navegador (applyRoleFilter) precisa disso pra manter na lista a
  # conversa em que o usuário é participante e não responsável.
  def push_data
    data = super.merge(participant_ids: conversation_participants.pluck(:user_id))
    return data unless account.feature_enabled?('sla')

    data.merge(
      applied_sla: applied_sla&.push_event_data,
      sla_events: sla_events.map(&:push_event_data),
      sla_policy_id: sla_policy_id
    )
  end
end
