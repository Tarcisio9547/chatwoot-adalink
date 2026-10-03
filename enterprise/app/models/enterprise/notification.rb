# Uma notificação continua apontando pra conversa mesmo depois de ela mudar de
# dono. Na caixa WhatsApp, se o dono da notificação deixou de enxergar a conversa
# pelo papel (RoleVisibility), o sino e o broadcast não mostram mais o conteúdo
# dela: o corpo do push vem vazio, o ator principal vai sem `messages` e o ator
# secundário, quando é uma mensagem, não é enviado. A notificação em si (tipo,
# id da conversa) continua, pra tela ainda poder listá-la.
module Enterprise::Notification
  def self.prepended(base)
    base.singleton_class.prepend(ClassMethods)
  end

  module ClassMethods
    # Decide em lote, antes de montar uma página de notificações, quais
    # conversas WhatsApp o dono de cada notificação ainda enxerga: 1 consulta de
    # papel por usuário e conta, em vez de uma por notificação.
    def preload_content_visibility(notifications)
      records = notifications.to_a
      ActiveRecord::Associations::Preloader.new(records: records, associations: :primary_actor).call
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

    def visible_conversation_ids(user, account, conversation_ids)
      account_user = user.account_users.find_by(account_id: account.id)
      return conversation_ids if Conversations::RoleVisibility.unrestricted?(user, account.id, account_user: account_user)

      scope = Conversation.where(id: conversation_ids)
      Conversations::RoleVisibility.filter(scope, user, account, account_user: account_user).pluck(:id)
    end

    def whatsapp_conversation?(actor)
      actor.is_a?(Conversation) && actor.inbox&.whatsapp?
    end
  end

  attr_writer :preloaded_content_visible

  def push_event_data
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

  # Usa o valor calculado em lote (página do sino) ou o calculado uma vez por
  # push_event_data; fora disso calcula na hora.
  def content_hidden?
    visible = @preloaded_content_visible
    visible = @scoped_content_visible if visible.nil?
    visible = compute_content_visible if visible.nil?
    !visible
  end

  def compute_content_visible
    conversation = primary_actor
    return true unless conversation.is_a?(Conversation) && conversation.inbox&.whatsapp?

    Conversations::RoleVisibility.visible_members(conversation, [user]).include?(user)
  end
end
