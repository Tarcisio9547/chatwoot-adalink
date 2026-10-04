class ConversationPolicy < ApplicationPolicy
  # Adalink: policy fora de uma requisição (menção, macro, ação em massa), com o AccountUser do
  # usuário na conta da conversa.
  def self.for_user(user, conversation, account_user: nil)
    account = conversation.account
    account_user ||= AccountUser.find_by(account_id: account.id, user_id: user.id)
    new({ user: user, account: account, account_user: account_user }, conversation)
  end

  def index?
    true
  end

  def destroy?
    return true if administrator?

    # Adalink: dono de inbox pessoal (convenção: inbox com EXATAMENTE 1 agente
    # associado pertence àquele agente — usado pra WhatsApp Pessoal). Permite
    # ele apagar conversas que estão na própria caixa, sem afetar regras de
    # inboxes compartilhadas (>1 agente) onde a default policy mantém apenas
    # admin podendo deletar.
    return false unless record.inbox

    members = record.inbox.inbox_members
    members.count == 1 && members.first&.user_id == user.id
  end

  def show?
    administrator? || agent_bot? || agent_can_view_conversation?
  end

  # Adalink: criar, alterar ou remover participantes. Participar dá acesso à conversa,
  # então não pode ser aberto a quem apenas a enxerga: só administrador, agente com papel
  # sem restrição de conversas (sem custom_role, ou "Todas" no módulo enterprise) ou o
  # RESPONSÁVEL atual. Quem é só participante, ou tem visão "Minhas"/"Não atribuídas"
  # sem ser o responsável, não pode se adicionar (nem adicionar outros).
  def manage_participants?
    return false if agent_bot? || account_user.blank?

    administrator? || assigned_to_user? || unrestricted_conversation_role?
  end

  # Adalink: quem tem visão restrita ("Minhas" ou "Não atribuídas", custom_role sem
  # conversation_manage) só se atribui a uma conversa SEM responsável e só reatribui ou tira o
  # responsável se ele mesmo for o responsável atual. Administrador, agente sem custom_role e
  # "Todas" seguem como sempre. `new_assignee_id` é o alvo da troca (nil = tirar o responsável;
  # agente bot, passe nil). Vale para a tela, as ações em massa e as macros, em todos os canais.
  def change_assignee?(new_assignee_id)
    return true if agent_bot? || account_user.blank? || administrator? || unrestricted_conversation_role?
    return true if assigned_to_user?

    record.assignee_id.nil? && new_assignee_id.to_s == user.id.to_s
  end

  private

  # Papel padrão do Chatwoot (sem custom_role) enxerga e gerencia todas as conversas das
  # suas caixas. O módulo enterprise restringe isso para custom_role sem conversation_manage.
  def unrestricted_conversation_role?
    true
  end

  def agent_can_view_conversation?
    # `participant?` restaura o comportamento upstream do Chatwoot:
    # quando o agente é adicionado como Participant de uma conversa específica,
    # ele pode vê-la mesmo sem ser member da inbox. Necessário pra permitir
    # gestor (organograma CRM) ver conversas de WA Pessoal marcadas como
    # "trabalho" sem expor a inbox inteira do corretor. Adicionado em 2026-05-12.
    inbox_access? || team_access? || participant?
  end

  def administrator?
    account_user&.administrator?
  end

  def agent_bot?
    user.is_a?(AgentBot)
  end

  def inbox_access?
    user.inboxes.where(account_id: account&.id).exists?(id: record.inbox_id)
  end

  def team_access?
    return false if record.team_id.blank?

    user.teams.where(account_id: account&.id).exists?(id: record.team_id)
  end

  def assigned_to_user?
    record.assignee_id == user.id
  end

  def participant?
    record.conversation_participants.exists?(user_id: user.id)
  end
end

ConversationPolicy.prepend_mod_with('ConversationPolicy')
