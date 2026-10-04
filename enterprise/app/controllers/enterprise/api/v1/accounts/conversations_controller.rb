module Enterprise::Api::V1::Accounts::ConversationsController
  extend ActiveSupport::Concern

  def inbox_assistant
    assistant = @conversation.inbox.captain_assistant

    if assistant
      render json: { assistant: { id: assistant.id, name: assistant.name } }
    else
      render json: { assistant: nil }
    end
  end

  def reporting_events
    @reporting_events = @conversation.reporting_events.order(created_at: :asc)
  end

  def permitted_update_params
    super.merge(params.permit(:sla_policy_id))
  end

  # Com lock_to_single_conversation o builder devolve a conversa que o contato já
  # tem. Quem tem visão restrita e não enxerga essa conversa (em qualquer canal) recebe 404,
  # sem a conversa e sem postar a mensagem; o 404 não confirma que ela existe.
  def create
    hidden = false
    ActiveRecord::Base.transaction do
      @conversation = ConversationBuilder.new(params: params, contact_inbox: @contact_inbox).perform
      hidden = existing_conversation_hidden?
      Messages::MessageBuilder.new(Current.user, @conversation, params[:message]).perform if params[:message].present? && !hidden
    end
    head :not_found if hidden
  end

  private

  def existing_conversation_hidden?
    return false if @conversation.previously_new_record? || !Current.user.is_a?(User)

    policy = ConversationPolicy.for_user(Current.user, @conversation)
    policy.restricted_role? && !policy.show?
  end

  def copilot_params
    params.permit(:previous_history, :message, :assistant_id)
  end
end
