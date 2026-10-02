# `active?` só confere se o usuário tem alguma permissão de conversa na conta
# (o papel Setor tem conversation_participating_manage), então `execute`
# precisa checar se ESSA conversa é visível pra ele: sem isso, o Copilot
# devolveria a conversa de um colega, com as mensagens privadas.
class Captain::Tools::Copilot::GetConversationService < Captain::Tools::BaseTool
  def self.name
    'get_conversation'
  end
  description 'Get details of a conversation including messages and contact information'

  param :conversation_id, type: :integer, desc: 'ID of the conversation to retrieve', required: true

  def execute(conversation_id:)
    conversation = Conversation.find_by(display_id: conversation_id, account_id: @assistant.account_id)
    return 'Conversation not found' if conversation.blank?
    return 'Conversation not found' unless visible_to_user?(conversation)

    conversation.to_llm_text(include_private_messages: true)
  end

  def active?
    user_has_permission('conversation_manage') ||
      user_has_permission('conversation_unassigned_manage') ||
      user_has_permission('conversation_participating_manage')
  end

  private

  # Só em Channel::Whatsapp, além da permissão geral da ferramenta (active?),
  # confere se a conversa ESPECÍFICA pedida é visível pro papel do usuário
  # (mesma regra de Conversations::RoleVisibility usada pela busca/eventos ao
  # vivo). Em outras caixas, comportamento idêntico ao upstream (active? já
  # era a única checagem).
  def visible_to_user?(conversation)
    return true unless conversation.inbox&.whatsapp?
    return true if @user.blank?

    Conversations::RoleVisibility.visible_members(conversation, [@user]).include?(@user)
  end
end
