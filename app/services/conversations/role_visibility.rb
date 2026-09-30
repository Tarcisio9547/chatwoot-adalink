# Adalink: helper único de visibilidade por papel, reaproveitado pela busca (#2083)
# e pelos avisos/eventos ao vivo (#2084) em caixas Channel::Whatsapp.
#
# Segue exatamente a mesma regra hierárquica que
# Enterprise::Conversations::PermissionFilterService já aplica na lista de
# conversas (conversation_manage > conversation_unassigned_manage >
# conversation_participating_manage), mais o participant explícito que
# ConversationPolicy#participant? já reconhece pra visão individual.
#
# Não decide sozinho quando aplicar a regra: quem chama (SearchService,
# NotificationListener, ActionCableListener) escolhe caixa por caixa,
# restringindo a Channel::Whatsapp.
class Conversations::RoleVisibility
  class << self
    # Um usuário específico pode ver esta conversa?
    def visible_to?(user, conversation)
      return true if user.is_a?(AgentBot)

      account_user = account_user_for(user, conversation.account_id)
      return false if account_user.blank?
      return true if account_user.administrator?

      permissions = account_user.permissions

      return true if permissions.include?('conversation_manage')
      return unassigned_or_mine?(permissions, user, conversation) if permissions.include?('conversation_unassigned_manage')
      return participating?(permissions, user, conversation) if permissions.include?('conversation_participating_manage')

      # Adalink: agente sem papel personalizado (custom_role) segue o
      # comportamento atual, sem restrição adicional por conversa.
      true
    end

    # Dado um conjunto de usuários (tipicamente membros da inbox), devolve só
    # quem pode ver a conversa. Não adiciona ninguém de fora da lista — quem
    # chama decide se soma administradores que não são membros (o
    # ActionCableListener já faz isso via user_tokens; o NotificationListener
    # nunca fez, então não fazemos aqui).
    def visible_members(conversation, members)
      account_id = conversation.account_id
      restricted, unrestricted = members.to_a.uniq.partition { |member| custom_role_restricted?(member, account_id) }

      unrestricted + restricted.select { |member| visible_to?(member, conversation) }
    end

    # Escopo de conversas visíveis pro usuário, seguindo a mesma regra.
    # Usado pela busca (#2083), que já recebe o escopo pré-filtrado por inbox.
    def filter(conversations, user, account)
      account_user = account_user_for(user, account.id)
      return conversations if account_user.blank? || account_user.administrator?

      permissions = account_user.permissions
      return conversations if permissions.include?('conversation_manage')

      if permissions.include?('conversation_unassigned_manage')
        return conversations.where(assignee_id: [nil, user.id])
      end

      if permissions.include?('conversation_participating_manage')
        participant_ids = ConversationParticipant.where(user_id: user.id).pluck(:conversation_id)
        return conversations.where(assignee_id: user.id).or(conversations.where(id: participant_ids))
      end

      # Adalink: agente sem papel personalizado (custom_role) segue o
      # comportamento atual, sem restrição adicional.
      conversations
    end

    private

    def unassigned_or_mine?(_permissions, user, conversation)
      conversation.assignee_id.nil? || conversation.assignee_id == user.id
    end

    def participating?(_permissions, user, conversation)
      conversation.assignee_id == user.id || conversation.conversation_participants.exists?(user_id: user.id)
    end

    def custom_role_restricted?(member, account_id)
      account_user = account_user_for(member, account_id)
      return false if account_user.blank?
      return false if account_user.administrator?

      account_user.custom_role_id.present?
    end

    def account_user_for(user, account_id)
      return nil unless user.respond_to?(:account_users)

      user.account_users.find_by(account_id: account_id)
    end
  end
end
