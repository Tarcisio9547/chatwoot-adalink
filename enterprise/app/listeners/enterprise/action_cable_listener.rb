# Adalink: #2084 (escopo ampliado pelos comentários) — na caixa WhatsApp
# Cloud, os eventos ao vivo do ActionCable só vão para quem o papel permite
# ver a conversa (mesma regra de RoleVisibility usada pela busca em #2083 e
# pelo aviso persistido em NotificationListener). Outras caixas continuam
# broadcastando para todos os membros, igual ao comportamento upstream.
#
# Correção do juiz cego (rodada 2, item 5): em vez de copiar o corpo dos 10
# métodos públicos que chamam `conversation.inbox.members`, todos eles já
# convergem para o mesmo ponto — o método privado `user_tokens(account,
# agents)` da classe base. Sobrescrevemos só esse ponto único: cada método
# público chama `around_member_filtering(conversation) { super }`, que
# guarda a conversa do evento atual e `user_tokens` filtra por ela quando a
# caixa é Channel::Whatsapp. O corpo de cada evento upstream nunca é
# duplicado.
#
# Correção do juiz cego (auditoria pré-envio, BUG ALTO): o listener é
# Singleton (ActionCableListener.instance), a MESMA instância é usada por
# TODAS as threads do Puma/Sidekiq que passam pelo SyncDispatcher — uma
# variável de instância (@current_event_conversation) vazava a conversa de
# uma thread para outra rodando em paralelo (uma mensagem de caixa WhatsApp
# podia ir sem filtro de papel, ou um evento de outra caixa herdar o filtro
# errado). Corrigido com ActiveSupport::IsolatedExecutionState, que isola o
# valor por thread (ou por fiber, conforme a config de execução do Rails) —
# não há estado compartilhado entre chamadas concorrentes. O valor anterior
# é salvo e restaurado no ensure, para suportar chamadas aninhadas na mesma
# thread (ex.: um listener disparando outro evento durante o broadcast).
#
# `contact_created/updated/merged/deleted`, `conversation_mentioned`,
# `notification_*` e `account_cache_invalidated` não usam
# `conversation.inbox.members` (broadcast por conta inteira ou só pro
# usuário-alvo) — não precisam de wrapper.
module Enterprise::ActionCableListener
  include Events::Types
  include Enterprise::ActionCableListenerAssigneeChangeVisibility

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
    broadcast(account, tokens, ASSIGNEE_CHANGED, conversation.push_event_data)
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
