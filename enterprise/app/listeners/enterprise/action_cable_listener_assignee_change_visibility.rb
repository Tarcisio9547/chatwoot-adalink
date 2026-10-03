# Resolve quem recebe o assignee.changed numa caixa Channel::Whatsapp, além de
# quem já enxerga a conversa depois da troca. Separado do
# Enterprise::ActionCableListener pra não estourar o limite de Metrics/ModuleLength.
module Enterprise::ActionCableListenerAssigneeChangeVisibility
  private

  # Quem PERDE a conversa numa reatribuição também precisa do evento
  # assignee.changed, pra tela dele tirar a conversa da lista — mesmo que a
  # regra de papel não deixe mais ele ver a conversa depois da troca (o
  # WhatsappParticipationCleanupListener já removeu o participante antes
  # deste método rodar). Por isso a lista de destino soma o assignee
  # anterior (se ele ainda for membro da inbox) aos destinatários calculados
  # com o estado já atualizado. Também cobre quem tinha o papel "Sem
  # atendente" e via a conversa por estar sem atendente: se ela deixou de
  # estar sem atendente, esse membro precisa do evento pra sumir da lista
  # dele, mesmo sem ter sido o assignee anterior.
  def assignee_changed_recipients(conversation, event)
    members = Conversations::RoleVisibility.visible_members(conversation, conversation.inbox.members)
    previous_assignee = previous_assignee_for(conversation, event)
    losing_unassigned_view = members_losing_unassigned_view(conversation, event)

    (members.to_a + [previous_assignee] + losing_unassigned_view).compact.uniq
  end

  def previous_assignee_for(conversation, event)
    previous_assignee_id, = Array(changed_attributes_for(event)['assignee_id'])
    return nil if previous_assignee_id.blank?

    conversation.inbox.members.find_by(id: previous_assignee_id)
  end

  # Adalink: membros com papel "Sem atendente" (conversation_unassigned_manage)
  # que viam a conversa por ela estar sem atendente, e que passaram a não vê-la
  # mais porque agora ela tem atendente. Sem isso, a tela deles não some a
  # conversa que deixou de estar sem atendente.
  def members_losing_unassigned_view(conversation, event)
    previous_assignee_id, = Array(changed_attributes_for(event)['assignee_id'])
    return [] if previous_assignee_id.present?
    return [] if conversation.assignee_id.blank?

    Conversations::RoleVisibility.unassigned_manage_only_members(conversation.inbox.members, conversation.account_id)
  end

  def changed_attributes_for(event)
    event.data[:changed_attributes] || {}
  end
end
