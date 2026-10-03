module Enterprise::AsyncDispatcher
  # O ParticipationListener roda no job com a conversa recarregada, sem a caixa
  # carregada. Levar o tipo de canal no payload do assignee.changed deixa ele
  # decidir se a caixa e WhatsApp sem uma consulta por job: os listeners
  # sincronos ja carregaram a caixa nesta mesma instancia, entao aqui o custo
  # liquido e zero. So esse evento leva a chave (e o unico consumidor).
  def dispatch(event_name, timestamp, data)
    conversation = data[:conversation]
    if event_name == Events::Types::ASSIGNEE_CHANGED && conversation.is_a?(Conversation)
      data = data.merge(channel_type: conversation.inbox&.channel_type)
    end
    super(event_name, timestamp, data)
  end

  def listeners
    super + [
      CaptainListener.instance
    ]
  end
end
