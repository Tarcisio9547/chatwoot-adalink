# Adalink: helper único de visibilidade por papel, reaproveitado pela busca (#2083)
# e pelos avisos/eventos ao vivo (#2084) em caixas Channel::Whatsapp.
#
# Segue exatamente a mesma regra hierárquica que
# Enterprise::Conversations::PermissionFilterService já aplica na lista de
# conversas (conversation_manage > conversation_unassigned_manage >
# conversation_participating_manage), mais o participant explícito que
# ConversationPolicy#participant? já reconhece pra visão individual.
#
# Agente com custom_role SEM nenhuma das três permissões de conversa fica
# sem ver nada (igual ao Enterprise::Conversations::PermissionFilterService
# nativo, que devolve Conversation.none nesse caso). Só agente SEM
# custom_role e administrador ficam sem filtro.
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
      return true if account_user.custom_role_id.blank?

      tier_grants_access?(permission_tier(account_user.permissions), conversation, user.id) do
        conversation.conversation_participants.exists?(user_id: user.id)
      end
    end

    # Dado um conjunto de usuários (tipicamente membros da inbox), devolve só
    # quem pode ver a conversa. Não adiciona ninguém de fora da lista — quem
    # chama decide se soma administradores que não são membros (o
    # ActionCableListener já faz isso via user_tokens; o NotificationListener
    # nunca fez, então não fazemos aqui).
    #
    # Carrega AccountUser (com custom_role) e ConversationParticipant em lote
    # para todos os membros de uma vez, em vez de 1 query por membro.
    def visible_members(conversation, members)
      members = members.to_a.uniq
      return members if members.empty?

      account_users_by_user_id = account_users_for(members, conversation.account_id)
      participant_user_ids = ConversationParticipant.where(conversation: conversation, user_id: members.map(&:id)).pluck(:user_id).to_set

      members.select { |member| member_visible?(member, conversation, account_users_by_user_id[member.id], participant_user_ids) }
    end

    # Escopo de conversas visíveis pro usuário, seguindo a mesma regra.
    # Usado pela busca (#2083), que já recebe o escopo pré-filtrado por inbox.
    def filter(conversations, user, account)
      account_user = account_user_for(user, account.id)
      return conversations if account_user.blank? || account_user.administrator?
      return conversations if account_user.custom_role_id.blank?

      case permission_tier(account_user.permissions)
      when :manage_all
        conversations
      when :unassigned
        conversations.where(assignee_id: [nil, user.id])
      when :participating
        participant_ids = ConversationParticipant.where(user_id: user.id).select(:conversation_id)
        conversations.where(assignee_id: user.id).or(conversations.where(id: participant_ids))
      else
        conversations.none
      end
    end

    # Usado pelo ActionCableListener (#2084, item 7): membro cujo ÚNICO
    # acesso à conversa vem de conversation_unassigned_manage - ou seja, só
    # vê enquanto ela estiver sem atendente. Serve pra saber quem precisa do
    # evento assignee_changed quando a conversa deixa de estar sem atendente.
    def unassigned_manage_only?(member, account_id)
      account_user = account_user_for(member, account_id)
      unassigned_manage_only_account_user?(account_user)
    end

    # Mesma checagem que unassigned_manage_only?, mas em lote (1 query pro
    # conjunto inteiro de membros, não 1 por membro).
    def unassigned_manage_only_members(members, account_id)
      members = members.to_a.uniq
      return [] if members.empty?

      account_users_by_user_id = account_users_for(members, account_id)
      members.select { |member| unassigned_manage_only_account_user?(account_users_by_user_id[member.id]) }
    end

    # Agente sem custom_role e administrador não passam por nenhuma query
    # extra (busca sai cedo antes de tocar em ConversationParticipant/ids).
    def unrestricted?(user, account_id)
      account_user = account_user_for(user, account_id)
      account_user.blank? || account_user.administrator? || account_user.custom_role_id.blank?
    end

    private

    def unassigned_manage_only_account_user?(account_user)
      return false if account_user.blank? || account_user.administrator?
      return false if account_user.custom_role_id.blank?

      permission_tier(account_user.permissions) == :unassigned
    end

    def permission_tier(permissions)
      return :manage_all if permissions.include?('conversation_manage')
      return :unassigned if permissions.include?('conversation_unassigned_manage')
      return :participating if permissions.include?('conversation_participating_manage')

      :none
    end

    def member_visible?(member, conversation, account_user, participant_user_ids)
      return true if member.is_a?(AgentBot)
      return false if account_user.blank?
      return true if account_user.administrator?
      return true if account_user.custom_role_id.blank?

      tier_grants_access?(permission_tier(account_user.permissions), conversation, member.id) { participant_user_ids.include?(member.id) }
    end

    # Regra comum aos dois modos de checagem (usuário único em visible_to?,
    # membro em lote em member_visible?): dado o "tier" de permissão já
    # resolvido, decide se target_id vê a conversa. participant? é um bloco
    # porque cada chamador resolve isso de um jeito diferente (query pontual
    # vs. Set pré-carregado em lote).
    def tier_grants_access?(tier, conversation, target_id)
      case tier
      when :manage_all then true
      when :unassigned then conversation.assignee_id.nil? || conversation.assignee_id == target_id
      when :participating then conversation.assignee_id == target_id || yield
      else false
      end
    end

    def account_users_for(members, account_id)
      AccountUser.where(account_id: account_id, user_id: members.map(&:id))
                 .includes(:custom_role)
                 .index_by(&:user_id)
    end

    def account_user_for(user, account_id)
      return nil unless user.respond_to?(:account_users)

      user.account_users.find_by(account_id: account_id)
    end
  end
end
