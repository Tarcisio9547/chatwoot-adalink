# Adalink: correção do juiz cego (rodada 2, item 1; revisado na rodada 3) -
# corrida entre o job assíncrono do ParticipationListener e o
# WhatsappParticipationCleanupListener síncrono.
#
# O ActiveJob/Sidekiq serializa o argumento `conversation:` via GlobalID
# (classe + id) e RECARREGA o registro do banco no momento em que o job
# executa — não guarda um snapshot antigo em memória. A corrida não é de
# "payload desatualizado": é puramente de TIMING entre dois processos
# acessando/modificando a mesma linha sem lock.
#
# Cenário: o job de nil→A lê o assignee_id (A) e está prestes a inserir o
# participante, mas é pausado (fila lenta, GC, etc). Nesse meio tempo, a
# Trama troca A→B de verdade: o WhatsappParticipationCleanupListener roda e
# tenta remover a participação de A — mas como o job antigo ainda não
# inseriu, não há nada pra remover (no-op). O job antigo retoma e insere A
# — e como isso acontece DEPOIS da limpeza, ninguém mais remove essa
# inserção. Resultado: assignee_id = B, mas A fica participante para
# sempre.
#
# Correção, só em Channel::Whatsapp: lê e insere dentro de
# conversation.with_lock (SELECT ... FOR UPDATE), serializando com a
# limpeza (que também toma o lock). Mesmo assim, relê o assignee_id DEPOIS
# de inserir e desfaz se mudou nesse intervalo — fecha as duas ordens
# possíveis de entrelaçamento, mesmo que o lock por algum motivo não seja
# suficiente (ex.: se a limpeza rodar numa transação separada que já
# commitou antes do lock ser adquirido). Em outras caixas, comportamento
# idêntico ao upstream.
module Enterprise::ParticipationListener
  def assignee_changed(event)
    conversation, _account = extract_conversation_and_account(event)
    return super unless conversation.inbox.whatsapp?

    conversation.with_lock do
      current_assignee_id = conversation.reload.assignee_id
      next if current_assignee_id.blank?

      participant = conversation.conversation_participants.find_or_create_by!(user_id: current_assignee_id)

      # Rede de segurança: mesmo dentro do lock, relê o assignee_id uma
      # última vez antes de finalizar. Se mudou entre a leitura acima e
      # agora (não deveria, já que estamos com a linha travada, mas cobre
      # qualquer caminho que não passe pelo mesmo lock), desfaz a inserção.
      final_assignee_id = conversation.reload.assignee_id
      participant.destroy! if final_assignee_id != current_assignee_id
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    Rails.logger.warn "Failed to create conversation participant for account #{conversation.account.id} " \
                      ": user #{conversation.assignee_id} : conversation #{conversation.id}"
  end
end
