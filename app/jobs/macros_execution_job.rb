class MacrosExecutionJob < ApplicationJob
  queue_as :medium

  def perform(macro, conversation_ids:, user:)
    account = macro.account
    conversations = executable_conversations(account, conversation_ids, user)

    return if conversations.blank?

    conversations.each do |conversation|
      ::Macros::ExecutionService.new(macro, conversation, user).perform
    end
  end

  private

  # Ponto de extensão: a edição Enterprise restringe às conversas que o usuário enxerga.
  def executable_conversations(account, conversation_ids, _user)
    account.conversations.where(display_id: conversation_ids.to_a)
  end
end

MacrosExecutionJob.prepend_mod_with('MacrosExecutionJob')
