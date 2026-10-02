# Na caixa WhatsApp o responsável é lido do banco, dentro de um lock de linha, e
# não do payload do evento: o job assíncrono pode rodar depois de uma nova troca
# (A->B) e, sem isso, reinseriria o responsável antigo como participante pra
# sempre. O lock serializa com WhatsappParticipationCleanupListener, que remove
# o responsável anterior. Outras caixas seguem o comportamento upstream.
module Enterprise::ParticipationListener
  def assignee_changed(event)
    conversation, _account = extract_conversation_and_account(event)
    return super unless conversation.inbox.whatsapp?

    add_current_assignee_as_participant(conversation.id)
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    Rails.logger.warn "Failed to create conversation participant for account #{conversation.account_id} " \
                      ": conversation #{conversation.id}"
  end

  private

  # Trava e lê uma instância NOVA da conversa, nunca a do evento: reload nela
  # apagaria os saved_changes que outros callbacks ainda podem ler.
  def add_current_assignee_as_participant(conversation_id)
    Conversation.transaction do
      locked = Conversation.lock.find_by(id: conversation_id)
      next if locked.nil? || locked.assignee_id.blank?

      participant = locked.conversation_participants.find_or_create_by!(user_id: locked.assignee_id)

      # Rede de segurança: se o responsável mudou entre a leitura e agora, desfaz.
      final_assignee_id = Conversation.where(id: conversation_id).pick(:assignee_id)
      participant.destroy! if final_assignee_id != locked.assignee_id
    end
  end
end
