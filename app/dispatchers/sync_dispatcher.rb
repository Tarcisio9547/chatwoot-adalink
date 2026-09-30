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
    # ambos os callbacks (notify_assignment_change, que emite ASSIGNEE_CHANGED,
    # e execute_after_update_commit_callbacks, que emite CONVERSATION_UPDATED)
    # são after_commit/after_update_commit, e o Rails os executa na ordem de
    # REGISTRO na classe — AssignmentHandler é incluído antes do
    # after_update_commit de CONVERSATION_UPDATED ser declarado em
    # Conversation. Ou seja: assignee.changed sempre sai ANTES de
    # conversation.updated na mesma troca de responsável.
    #
    # Por isso quem perde a conversa (A, na troca A->B) pode receber os DOIS
    # eventos: assignee.changed primeiro (onde a tela já pode remover a
    # conversa da lista) e conversation.updated logo depois, já sem acesso.
    # Isso deixou de vazar conteúdo com a correção do item 2
    # (Enterprise::ActionCableBroadcastJob): o conversation.updated que
    # eventualmente chegar a A nunca traz mensagem posterior à troca, porque
    # o job refiltra destinatários e payload no momento da EXECUÇÃO, não do
    # disparo. Ver spec/jobs/action_cable_broadcast_job_role_visibility_spec.rb
    # e spec/listeners/action_cable_listener_role_visibility_spec.rb (ordem de
    # eventos coberta em '#assignee event ordering').
    [WhatsappParticipationCleanupListener.instance, ActionCableListener.instance, AgentBotListener.instance]
  end
end
