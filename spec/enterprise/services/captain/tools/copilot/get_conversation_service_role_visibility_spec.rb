require 'rails_helper'

# Adalink: correcao do juiz cego (rodada 3, item 5, BAIXA/upstream) -
# GetConversationService#active? so checava a permissao GERAL de conversa
# na conta, nao se o usuario podia ver AQUELA conversa especifica. Um
# agente com papel Setor conseguia pedir pro Copilot a conversa de um
# colega (com mensagens privadas) numa caixa Channel::Whatsapp.
describe Captain::Tools::Copilot::GetConversationService, 'role visibility (item 5)' do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:setor_role) { create(:custom_role, account: account, permissions: %w[conversation_participating_manage]) }
  let(:agent) { create(:user, account: account) }
  let(:colleague) { create(:user, account: account) }
  let(:service) { described_class.new(assistant, user: agent) }

  before { AccountUser.find_by(user: agent, account: account).update(custom_role: setor_role) }

  context 'when the inbox is Channel::Whatsapp' do
    let!(:whatsapp_inbox) do
      create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox
    end

    before do
      create(:inbox_member, user: agent, inbox: whatsapp_inbox)
      create(:inbox_member, user: colleague, inbox: whatsapp_inbox)
    end

    it "does not return a colleague's conversation to a Setor-role agent" do
      colleague_conversation = create(:conversation, account: account, inbox: whatsapp_inbox, assignee: colleague,
                                                      identifier: SecureRandom.hex(6))
      create(:message, conversation: colleague_conversation, message_type: 'outgoing', content: 'segredo do colega', private: true)

      result = service.execute(conversation_id: colleague_conversation.display_id)

      expect(result).to eq('Conversation not found')
      expect(result).not_to include('segredo do colega')
    end

    it 'returns the agent own conversation' do
      own_conversation = create(:conversation, account: account, inbox: whatsapp_inbox, assignee: agent)

      result = service.execute(conversation_id: own_conversation.display_id)

      expect(result).to eq(own_conversation.to_llm_text(include_private_messages: true))
    end

    it 'returns a conversation the agent explicitly participates in' do
      colleague_conversation = create(:conversation, account: account, inbox: whatsapp_inbox, assignee: colleague)
      create(:conversation_participant, conversation: colleague_conversation, account: account, user: agent)

      result = service.execute(conversation_id: colleague_conversation.display_id)

      expect(result).to eq(colleague_conversation.to_llm_text(include_private_messages: true))
    end
  end

  context 'when the inbox is not Channel::Whatsapp' do
    let!(:other_inbox) { create(:inbox, account: account) }

    before do
      create(:inbox_member, user: agent, inbox: other_inbox)
      create(:inbox_member, user: colleague, inbox: other_inbox)
    end

    it "keeps returning a colleague's conversation (current behaviour, unchanged)" do
      colleague_conversation = create(:conversation, account: account, inbox: other_inbox, assignee: colleague)

      result = service.execute(conversation_id: colleague_conversation.display_id)

      expect(result).to eq(colleague_conversation.to_llm_text(include_private_messages: true))
    end
  end
end
