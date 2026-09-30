# Adalink: correção do juiz cego (#2083/#2084, decisão ALTA opção B) - o
# Chatwoot upstream (ParticipationListener) só adiciona o novo responsável
# como participante e nunca remove o anterior. Isso deixa quem perdeu a
# conversa continuar recebendo eventos ao vivo (message_created,
# conversation_updated) e achando ela na busca, via
# Enterprise::ConversationPolicy#participant?/Conversations::RoleVisibility.
#
# Escopado a Channel::Whatsapp: remove SÓ o responsável ANTERIOR (não mexe
# em participantes adicionados manualmente). Registrado no SyncDispatcher,
# antes do ActionCableListener, para a remoção já valer no próprio evento ao
# vivo desta troca.
#
# Correção do juiz cego (rodada 3, item 1): toma o mesmo
# conversation.with_lock que Enterprise::ParticipationListener usa pra
# inserir o novo responsável, pra serializar de verdade os dois caminhos —
# sem isso, o job assíncrono de uma troca anterior (ainda não processado)
# podia inserir o responsável já removido aqui, depois da limpeza já ter
# rodado (ver comentário em enterprise/app/listeners/enterprise/participation_listener.rb).
#
# Decisão do orquestrador (rodada 3, item 4): esta remoção roda pra QUALQUER
# responsável anterior, inclusive administrador ou agente sem custom_role —
# não só quem tem papel restrito. Mantido de propósito: admin e agente sem
# papel continuam vendo TODAS as conversas da caixa pela visão "Todas"
# (Conversations::RoleVisibility os trata como unrestricted?/administrator?,
# sem depender de ser participante ou assignee), então sair da lista de
# participantes não tira o acesso deles a essa conversa — só evita que a
# tabela conversation_participants acumule entradas de quem já não é mais o
# responsável, para todo mundo, de forma consistente.
class WhatsappParticipationCleanupListener < BaseListener
  def assignee_changed(event)
    conversation, _account = extract_conversation_and_account(event)
    return unless conversation.inbox.whatsapp?

    previous_assignee_id = previous_assignee_id_for(event)
    return if previous_assignee_id.blank?

    conversation.with_lock do
      current_assignee_id = conversation.reload.assignee_id
      next if previous_assignee_id == current_assignee_id

      # Query direto na classe (não via conversation.conversation_participants,
      # cuja associação em cache não é resetada por um destroy_all escopado
      # com .where) e reset explícito pra quem já tiver a associação carregada.
      ConversationParticipant.where(conversation_id: conversation.id, user_id: previous_assignee_id).destroy_all
      conversation.conversation_participants.reset
    end
  end

  private

  def previous_assignee_id_for(event)
    changed_attributes = event.data[:changed_attributes] || {}
    previous_assignee_id, = Array(changed_attributes['assignee_id'])
    previous_assignee_id
  end
end
