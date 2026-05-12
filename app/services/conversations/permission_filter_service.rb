class Conversations::PermissionFilterService
  attr_reader :conversations, :user, :account

  def initialize(conversations, user, account)
    @conversations = conversations
    @user = user
    @account = account
  end

  def perform
    return conversations if user_role == 'administrator'

    accessible_conversations
  end

  private

  def accessible_conversations
    inbox_scope = conversations.where(inbox: user.inboxes.where(account_id: account.id))

    # Adalink: inclui conversas onde o usuário é Participant explícito
    # (ex.: gestor vendo conversa WA Pessoal marcada como "trabalho" pela corretora).
    participant_ids = ConversationParticipant.where(user_id: user.id).pluck(:conversation_id)
    return inbox_scope if participant_ids.empty?

    inbox_scope.or(conversations.where(id: participant_ids))
  end

  def account_user
    AccountUser.find_by(account_id: account.id, user_id: user.id)
  end

  def user_role
    account_user&.role
  end
end

Conversations::PermissionFilterService.prepend_mod_with('Conversations::PermissionFilterService')
