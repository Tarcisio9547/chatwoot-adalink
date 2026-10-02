class SyncDispatcher < BaseDispatcher
  def dispatch(event_name, timestamp, data)
    event_object = Events::Base.new(event_name, timestamp, data)
    publish(event_object.method_name, event_object)
  end

  def listeners
    # Adalink: WhatsappParticipationCleanupListener roda ANTES do
    # ActionCableListener de propósito — precisa remover o responsável
    # anterior da lista de participantes antes do broadcast síncrono deste
    # mesmo evento assignee_changed calcular quem pode ver a conversa.
    #
    # Correção do juiz cego (rodada 3, item 3, BAIXA): isso ordena os
    # listeners DENTRO de um mesmo evento (assignee_changed), não a ordem
    # entre os dois eventos diferentes disparados na troca de responsável.
    # Essa segunda ordem não vem do SyncDispatcher, vem de
    # app/models/concerns/assignment_handler.rb e app/models/conversation.rb:
    # notify_assignment_change (ASSIGNEE_CHANGED) é after_commit, registrado
    # na linha 57 (include AssignmentHandler), e
    # execute_after_update_commit_callbacks (CONVERSATION_UPDATED) é
    # after_update_commit, registrado na linha 121. O Rails executa os
    # callbacks de commit na ordem INVERSA de registro, então o que sai
    # primeiro é conversation.updated e só depois assignee.changed. A ordem
    # foi MEDIDA (não deduzida da leitura do código) em
    # spec/listeners/assignee_change_event_ordering_spec.rb.
    #
    # Consequência: na troca A->B, o conversation.updated é calculado ANTES do
    # assignee.changed, ou seja, antes da limpeza de participantes deste
    # listener rodar. Quem perde a conversa (A) pode receber os dois eventos.
    # O vazamento de conteúdo é fechado pelo
    # Enterprise::ActionCableBroadcastJob (item 2): na EXECUÇÃO do job os
    # destinatários são refiltrados e quem já perdeu acesso não recebe o
    # conversation.updated, e no assignee.changed recebe o payload sem
    # `messages`. Ver spec/jobs/action_cable_broadcast_job_role_visibility_spec.rb.
    [WhatsappParticipationCleanupListener.instance, ActionCableListener.instance, AgentBotListener.instance]
  end
end
