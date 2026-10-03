# Uma notificação continua apontando pra conversa mesmo depois de ela mudar de
# dono. Na caixa WhatsApp, se o dono da notificação deixou de enxergar a conversa
# pelo papel (RoleVisibility), o sino e o broadcast não mostram mais o conteúdo
# dela: o corpo do push vem vazio, o ator principal vai sem `messages` e o ator
# secundário, quando é uma mensagem, não é enviado. A notificação em si (tipo,
# id da conversa) continua, pra tela ainda poder listá-la.
#
# Limites conhecidos: só o conteúdo de mensagens some. Os metadados da conversa
# (contato, etiquetas, responsável atual) seguem no ator principal, como no
# upstream. E o que já saiu quando a notificação foi criada (e-mail, push
# entregue) não é retirado depois: naquele momento o dono ainda enxergava a
# conversa.
module Enterprise::Notification
  def self.prepended(base)
    base.singleton_class.prepend(ClassMethods)
  end

  module ClassMethods
    # Decide em lote, antes de montar uma página de notificações, quais
    # conversas WhatsApp o dono de cada notificação ainda enxerga: 1 consulta de
    # papel por usuário e conta, em vez de uma por notificação. As conversas e as
    # caixas vêm em uma consulta cada (o sino carregaria uma por notificação).
    def preload_content_visibility(notifications)
      records = notifications.to_a
      ActiveRecord::Associations::Preloader.new(records: records, associations: :primary_actor).call
      conversations = records.map(&:primary_actor).grep(Conversation)
      ActiveRecord::Associations::Preloader.new(records: conversations, associations: :inbox).call
      records.group_by { |notification| [notification.user_id, notification.account_id] }.each_value do |group|
        preload_group_visibility(group)
      end
    end

    private

    def preload_group_visibility(group)
      whatsapp = group.select { |notification| whatsapp_conversation?(notification.primary_actor) }
      return if whatsapp.empty?

      visible_ids = visible_conversation_ids(whatsapp.first.user, whatsapp.first.account, whatsapp.map(&:primary_actor_id))
      whatsapp.each { |notification| notification.preloaded_content_visible = visible_ids.include?(notification.primary_actor_id) }
    end

    # O controller já carregou o AccountUser da requisição (Current.account_user):
    # reaproveita quando é do mesmo usuário e conta.
    def visible_conversation_ids(user, account, conversation_ids)
      account_user = request_account_user(user, account) || user.account_users.find_by(account_id: account.id)
      return conversation_ids if Conversations::RoleVisibility.unrestricted?(account_user)

      scope = Conversation.where(id: conversation_ids)
      Conversations::RoleVisibility.filter(scope, user, account_user: account_user).pluck(:id)
    end

    def request_account_user(user, account)
      candidate = Current.account_user
      candidate if candidate&.user_id == user.id && candidate.account_id == account.id
    end

    def whatsapp_conversation?(actor)
      actor.is_a?(Conversation) && actor.inbox&.whatsapp?
    end
  end

  def preloaded_content_visible=(value)
    @preloaded_content_visible = value
  end

  def reload(*)
    @preloaded_content_visible = nil
    @whatsapp_conversation = nil
    super
  end

  # O ator principal é a conversa e o upstream carrega a caixa dela ao montar o
  # payload; carregar antes deixa a checagem de canal sem consulta extra. A
  # visibilidade é calculada uma vez por payload e não fica guardada: a conversa
  # pode mudar de dono entre dois eventos da mesma notificação.
  def push_event_data
    primary_actor.inbox if primary_actor.is_a?(Conversation)
    @scoped_content_visible = compute_content_visible
    super
  ensure
    @scoped_content_visible = nil
  end

  def push_message_body
    content_hidden? ? '' : super
  end

  def primary_actor_push_data
    data = super
    content_hidden? && data ? data.except(:messages) : data
  end

  def secondary_actor_push_data
    content_hidden? && secondary_actor.is_a?(Message) ? nil : super
  end

  private

  # Valor em lote (página do sino), ou o do payload em montagem; fora disso,
  # calcula na hora.
  def content_hidden?
    visible = @preloaded_content_visible
    visible = @scoped_content_visible if visible.nil?
    visible = compute_content_visible if visible.nil?
    !visible
  end

  def compute_content_visible
    conversation = primary_actor
    return true unless conversation.is_a?(Conversation) && whatsapp_conversation?(conversation)

    Conversations::RoleVisibility.visible_members(conversation, [user]).include?(user)
  end

  # O tipo de canal de uma caixa nunca muda, então fica guardado. Usa a caixa já
  # carregada; senão, uma consulta leve (sem carregar a caixa).
  def whatsapp_conversation?(conversation)
    return @whatsapp_conversation unless @whatsapp_conversation.nil?

    @whatsapp_conversation =
      if conversation.association(:inbox).loaded?
        conversation.inbox.whatsapp?
      else
        Conversation.joins(:inbox).exists?(id: conversation.id,
                                           inboxes: { channel_type: Conversations::RoleVisibility::WHATSAPP_CHANNEL_TYPE })
      end
  end
end
