class Captain::SummaryService < Captain::BaseTaskService
  pattr_initialize [:account!, :conversation_display_id!]

  def perform
    # model resolvido pelo base via feature_key 'editor' + preferência da account.
    make_api_call(
      messages: [
        { role: 'system', content: prompt_from_file('summary') },
        { role: 'user', content: conversation.to_llm_text(include_contact_details: false) }
      ]
    )
  end

  private

  def event_name
    'summarize'
  end
end
