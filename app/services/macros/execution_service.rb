class Macros::ExecutionService < ActionService
  def initialize(macro, conversation, user)
    super(conversation)
    @macro = macro
    @account = macro.account
    @user = user
    Current.user = user
  end

  def perform
    @macro.actions.each do |action|
      action = action.with_indifferent_access
      begin
        send(action[:action_name], action[:action_params])
      rescue StandardError => e
        ChatwootExceptionTracker.new(e, account: @account).capture_exception
      end
    end
  ensure
    Current.reset
  end

  private

  def assign_agent(agent_ids)
    agent_ids = agent_ids.map { |id| id == 'self' ? @user.id : id }
    return unless assignee_change_allowed?(agent_ids[0])

    super(agent_ids)
  end

  # Adalink: quem tem visão restrita só se atribui a conversa sem responsável e só reatribui/tira
  # o responsável se for o responsável atual (ConversationPolicy#change_assignee?), só troca de time
  # se isso não tirar o dono de outra pessoa (change_team?) e só muda o status do que enxerga
  # (change_status?). As outras ações da macro seguem rodando.
  def assignee_change_allowed?(target)
    target = nil if target.to_s == 'nil'
    conversation_policy.change_assignee?(target)
  end

  def assign_team(team_ids)
    return unless conversation_policy.change_team?(destination_team(team_ids))

    super
  end

  def remove_assigned_team(params)
    return unless conversation_policy.change_team?(nil)

    super
  end

  def change_status(status)
    return unless conversation_policy.change_status?

    super
  end

  def destination_team(team_ids)
    return nil if team_ids.blank? || %w[nil 0].include?(team_ids[0].to_s)

    @account.teams.find_by(id: team_ids[0])
  end

  def conversation_policy
    @conversation_policy ||= ConversationPolicy.for_user(@user, @conversation)
  end

  def add_private_note(message)
    return if conversation_a_tweet?

    params = { content: message[0], private: true }

    # Added reload here to ensure conversation us persistent with the latest updates
    mb = Messages::MessageBuilder.new(@user, @conversation.reload, params)
    mb.perform
  end

  def send_message(message)
    return if conversation_a_tweet?

    params = { content: message[0], private: false }

    # Added reload here to ensure conversation us persistent with the latest updates
    mb = Messages::MessageBuilder.new(@user, @conversation.reload, params)
    mb.perform
  end

  def send_attachment(blob_ids)
    return if conversation_a_tweet?

    return unless @macro.files.attached?

    blobs = ActiveStorage::Blob.where(id: blob_ids)

    return if blobs.blank?

    params = { content: nil, private: false, attachments: blobs }

    # Added reload here to ensure conversation us persistent with the latest updates
    mb = Messages::MessageBuilder.new(@user, @conversation.reload, params)
    mb.perform
  end

  def send_webhook_event(webhook_url)
    payload = @conversation.webhook_data.merge(event: 'macro.executed')
    WebhookJob.perform_later(webhook_url.first, payload)
  end
end
