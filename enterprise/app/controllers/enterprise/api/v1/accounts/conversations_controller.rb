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
  # tem. Numa caixa WhatsApp, quem não enxerga essa conversa pelo papel recebe 404,
  # sem a conversa e sem postar a mensagem.
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
    return false if @conversation.previously_new_record? || !@contact_inbox.inbox.whatsapp?

    Conversations::RoleVisibility.visible_members(@conversation, [Current.user]).exclude?(Current.user)
  end

  def copilot_params
    params.permit(:previous_history, :message, :assistant_id)
  end
end
