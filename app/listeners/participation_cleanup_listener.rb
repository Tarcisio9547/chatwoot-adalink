# Em TODOS os canais, quem perde a conversa deixa de ser participante. O
# ParticipationListener upstream só adiciona o novo responsável e nunca remove
# o anterior, que continuaria vendo a conversa nos eventos ao vivo, na busca e, com
# visão restrita ("Minhas"/"Não atribuídas"), na própria lista, para sempre.
# Remove só o responsável anterior (participantes manuais ficam; não há como
# distinguir se o responsável anterior também tinha sido adicionado à mão, então
# esse perde a participação junto) e roda no SyncDispatcher antes do
# ActionCableListener, pra valer no broadcast da própria troca. Vale também pra admin
# e agente sem papel: eles seguem vendo tudo pela visão "Todas"
# (Conversations::RoleVisibility.unrestricted?).
#
# Sem responsável anterior (primeira atribuição) não faz nenhuma consulta.
class ParticipationCleanupListener < BaseListener
  def assignee_changed(event)
    previous_assignee_id = previous_assignee_id_for(event)
    return if previous_assignee_id.blank?

    remove_previous_assignee(event.data[:conversation].id, previous_assignee_id)
  end

  private

  # Trava e lê uma instância NOVA da conversa, nunca a do evento: o objeto do
  # evento carrega os saved_changes que callbacks posteriores do mesmo
  # after_commit ainda leem (ex.: team.changed), e reload/with_lock apagam isso.
  # O lock serializa com o ParticipationListener, que insere o novo responsável, e
  # com a troca de responsável (o UPDATE também toma FOR NO KEY UPDATE). Sem ele, a
  # limpeza de uma troca antiga apagaria o participante de quem acabou de voltar
  # (B->A). FOR NO KEY UPDATE em vez de FOR UPDATE: o UPDATE do responsável também
  # o toma (segue serializando), mas ele não conflita com FOR KEY SHARE, o lock que
  # um INSERT com chave estrangeira pra conversa pediria. O schema de hoje não tem
  # essa FK; o modo mais fraco evita bloquear se algum dia vier.
  def remove_previous_assignee(conversation_id, previous_assignee_id)
    Conversation.transaction do
      locked = Conversation.lock('FOR NO KEY UPDATE').find_by(id: conversation_id)
      next if locked.nil? || locked.assignee_id == previous_assignee_id

      ConversationParticipant.where(conversation_id: conversation_id, user_id: previous_assignee_id).destroy_all
    end
  end

  def previous_assignee_id_for(event)
    changed_attributes = event.data[:changed_attributes] || {}
    previous_assignee_id, = Array(changed_attributes['assignee_id'])
    previous_assignee_id
  end
end
