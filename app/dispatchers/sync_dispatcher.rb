class SyncDispatcher < BaseDispatcher
  def dispatch(event_name, timestamp, data)
    event_object = Events::Base.new(event_name, timestamp, data)
    publish(event_object.method_name, event_object)
  end

  def listeners
    # ParticipationCleanupListener roda ANTES do ActionCableListener pra
    # remover o responsável anterior dos participantes antes do broadcast do
    # mesmo assignee_changed calcular quem pode ver a conversa.
    #
    # Isso ordena os listeners de um mesmo evento, não os eventos entre si. Na
    # troca de responsável, conversation.updated sai ANTES de assignee.changed
    # (callbacks de commit rodam na ordem inversa de registro; ver
    # spec/listeners/assignee_change_event_ordering_spec.rb), então quem perde a
    # conversa pode receber os dois. O conteúdo não vaza porque
    # Enterprise::ActionCableBroadcastJob refiltra os destinatários na execução.
    [ParticipationCleanupListener.instance, ActionCableListener.instance, AgentBotListener.instance]
  end
end
