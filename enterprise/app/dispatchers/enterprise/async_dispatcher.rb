module Enterprise::AsyncDispatcher
  # O ParticipationListener roda no job com a conversa recarregada, sem a caixa
  # carregada. O assignee.changed de uma caixa WhatsApp leva channel_type no
  # payload e o listener decide pela presenca da chave, sem uma consulta por job
  # (os listeners sincronos ja carregaram a caixa nesta mesma instancia, custo
  # liquido zero). Eventos de outras caixas e os demais eventos seguem com o
  # payload identico ao upstream.
  def dispatch(event_name, timestamp, data)
    conversation = data[:conversation]
    if event_name == Events::Types::ASSIGNEE_CHANGED && conversation.is_a?(Conversation) && conversation.inbox&.whatsapp?
      data = data.merge(channel_type: Conversations::RoleVisibility::WHATSAPP_CHANNEL_TYPE)
    end
    super(event_name, timestamp, data)
  end

  def listeners
    super + [
      CaptainListener.instance
    ]
  end
end
