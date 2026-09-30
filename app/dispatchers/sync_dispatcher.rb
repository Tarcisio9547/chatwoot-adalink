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
    [WhatsappParticipationCleanupListener.instance, ActionCableListener.instance, AgentBotListener.instance]
  end
end
