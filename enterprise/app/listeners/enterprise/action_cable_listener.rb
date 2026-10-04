# Na caixa WhatsApp Cloud, os eventos ao vivo do ActionCable só vão para quem o
# papel permite ver a conversa (mesma regra de RoleVisibility da busca e do
# NotificationListener). Outras caixas seguem o upstream: todos os membros.
#
# Os métodos públicos que chamam `conversation.inbox.members` convergem para
# `user_tokens(account, agents)` da classe base. Em vez de copiar o corpo de
# cada um, cada método chama `around_member_filtering(conversation) { super }`,
# que marca a conversa do evento, e só `user_tokens` filtra por ela.
#
# O listener é Singleton, compartilhado por todas as threads do Puma/Sidekiq:
# a marca fica em ActiveSupport::IsolatedExecutionState (por thread/fiber), nunca
# em variável de instância, que vazaria a conversa entre eventos concorrentes.
# O valor anterior é restaurado no ensure, pra suportar chamadas aninhadas.
#
# Eventos que não usam `conversation.inbox.members` (contact_*,
# conversation_mentioned, notification_*, account_cache_invalidated) não
# precisam do wrapper.
module Enterprise::ActionCableListener
  include Events::Types
  include Enterprise::ActionCableListenerAssigneeChangeVisibility
  include Enterprise::ActionCableListenerParticipants

  CURRENT_EVENT_CONVERSATION_KEY = :adalink_action_cable_listener_current_conversation

  def copilot_message_created(event)
    copilot_message = event.data[:copilot_message]
    copilot_thread = copilot_message.copilot_thread
    account = copilot_thread.account
    user = copilot_thread.user

    broadcast(account, [user.pubsub_token], COPILOT_MESSAGE_CREATED, copilot_message.push_event_data)
  end

  def message_created(event)
    around_member_filtering(event.data[:message]&.conversation) { super }
  end

  def message_updated(event)
    around_member_filtering(event.data[:message]&.conversation) { super }
  end

  def first_reply_created(event)
    around_member_filtering(event.data[:message]&.conversation) { super }
  end

  def conversation_created(event)
    around_member_filtering(event.data[:conversation]) { super }
  end

  def conversation_read(event)
    around_member_filtering(event.data[:conversation]) { super }
  end

  def conversation_status_changed(event)
    around_member_filtering(event.data[:conversation]) { super }
  end

  def conversation_updated(event)
    around_member_filtering(event.data[:conversation]) { super }
  end

  def conversation_typing_on(event)
    around_member_filtering(event.data[:conversation]) { super }
  end

  def conversation_typing_off(event)
    around_member_filtering(event.data[:conversation]) { super }
  end

  def assignee_changed(event)
    conversation = event.data[:conversation]
    return super unless conversation&.inbox&.whatsapp?

    # assignee_changed tem regra de destinatário própria (quem perde a
    # conversa, "Sem atendente" perdendo visão) — não é só um filtro de
    # user_tokens, então continua com override dedicado (ver
    # Enterprise::ActionCableListenerAssigneeChangeVisibility).
    _conversation, account = extract_conversation_and_account(event)
    recipients = assignee_changed_recipients(conversation, event)
    tokens = user_tokens(account, recipients)
    broadcast(account, tokens, ASSIGNEE_CHANGED, conversation.agent_push_event_data)
  end

  def team_changed(event)
    around_member_filtering(event.data[:conversation]) { super }
  end

  def conversation_contact_changed(event)
    around_member_filtering(event.data[:conversation]) { super }
  end

  private

  # Guarda a conversa do evento atual pra user_tokens filtrar por ela, roda
  # o bloco (que chama super, o método upstream original), e restaura o
  # valor anterior depois - mesmo se o bloco levantar, pra não vazar estado
  # entre eventos. Usa ActiveSupport::IsolatedExecutionState (isolado por
  # thread/fiber) em vez de variável de instância: o listener é Singleton
  # compartilhado entre todas as threads do Puma/Sidekiq, então uma
  # variável de instância vazaria a conversa de uma thread pra outra
  # rodando em paralelo no mesmo processo.
  def around_member_filtering(conversation)
    previous_conversation = ActiveSupport::IsolatedExecutionState[CURRENT_EVENT_CONVERSATION_KEY]
    ActiveSupport::IsolatedExecutionState[CURRENT_EVENT_CONVERSATION_KEY] = conversation
    yield
  ensure
    ActiveSupport::IsolatedExecutionState[CURRENT_EVENT_CONVERSATION_KEY] = previous_conversation
  end

  # Ponto único de filtragem: chamado pela classe base sempre que ela monta
  # tokens a partir de uma lista de agentes. Quando a chamada corresponde a
  # conversation.inbox.members de uma conversa Channel::Whatsapp (marcada
  # por around_member_filtering), filtra por RoleVisibility antes de somar
  # os tokens de admin. Fora disso (conta inteira, outro canal), idêntico
  # ao upstream.
  def user_tokens(account, agents)
    conversation = ActiveSupport::IsolatedExecutionState[CURRENT_EVENT_CONVERSATION_KEY]
    return super unless conversation&.inbox&.whatsapp?

    super(account, Conversations::RoleVisibility.visible_members(conversation, agents))
  end
end
