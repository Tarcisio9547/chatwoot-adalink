# Adalink: correção do juiz cego (rodada 2, item 1, MÉDIA) - corrida entre o
# job assíncrono do ParticipationListener e o
# WhatsappParticipationCleanupListener síncrono.
#
# Cenário: conversa nil→A dispara assignee_changed. O EventDispatcherJob
# (async) é enfileirado com o payload da conversa JÁ SERIALIZADA com
# assignee_id = A. Antes desse job rodar, a Trama troca A→B: o
# WhatsappParticipationCleanupListener (síncrono) já removeu A dos
# participantes. Quando o job antigo finalmente executa, ele insere A de
# volta via find_or_create_by!(user_id: conversation.assignee_id), usando o
# assignee_id desatualizado do momento do enqueue — reintroduzindo o
# vazamento que o cleanup listener corrigiu.
#
# Correção, só em Channel::Whatsapp: relê o assignee_id atual do banco antes
# de inserir. Se o banco não bate com o que o evento carrega, o job está
# desatualizado — usa o valor relido (o dono ATUAL) em vez do estampado no
# evento. Em outras caixas, comportamento idêntico ao upstream.
module Enterprise::ParticipationListener
  def assignee_changed(event)
    conversation, _account = extract_conversation_and_account(event)
    return super unless conversation.inbox.whatsapp?

    current_assignee_id = Conversation.where(id: conversation.id).pick(:assignee_id)
    return if current_assignee_id.blank?

    conversation.conversation_participants.find_or_create_by!(user_id: current_assignee_id)
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    Rails.logger.warn "Failed to create conversation participant for account #{conversation.account.id} " \
                      ": user #{current_assignee_id} : conversation #{conversation.id}"
  end
end
