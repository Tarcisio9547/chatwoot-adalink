class ConversationPolicy < ApplicationPolicy
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

  private

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
