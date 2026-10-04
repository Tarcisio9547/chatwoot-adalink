module PushDataHelper
  extend ActiveSupport::Concern

  def push_event_data
    Conversations::EventDataPresenter.new(self).push_data
  end

  # Adalink: payload SÓ para agentes (ActionCable do dashboard). participant_ids deixa o navegador
  # manter na lista a conversa em que o usuário é participante (applyRoleFilter). Nunca vai no
  # payload comum (push_event_data/webhook_data), que também chega ao contato (widget) e aos
  # webhooks externos e AgentBots.
  def agent_push_event_data
    push_event_data.merge(participant_ids: conversation_participants.pluck(:user_id))
  end

  def lock_event_data
    Conversations::EventDataPresenter.new(self).lock_data
  end

  def webhook_data
    Conversations::EventDataPresenter.new(self).push_data
  end
end
