require 'rails_helper'

RSpec.describe 'Public Inbox Contact Conversation Messages API', type: :request do
  let!(:api_channel) { create(:channel_api) }
  let!(:contact) { create(:contact, phone_number: '+324234324', email: 'dfsadf@sfsda.com') }
  let!(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: api_channel.inbox) }
  let!(:conversation)  { create(:conversation, contact: contact, contact_inbox: contact_inbox) }

  describe 'GET /public/api/v1/inboxes/{identifier}/contact/{source_id}/conversations/{conversation_id}/messages' do
    it 'return the messages for that conversation' do
      2.times.each { create(:message, account: conversation.account, inbox: conversation.inbox, conversation: conversation) }

      get "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{contact_inbox.source_id}/conversations/#{conversation.display_id}/messages"

      expect(response).to have_http_status(:success)
      data = response.parsed_body
      expect(data.length).to eq 2
    end
  end

  describe 'POST /public/api/v1/inboxes/{identifier}/contact/{source_id}/conversations/{conversation_id}/messages' do
    it 'creates a message in the conversation' do
      post "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{contact_inbox.source_id}/conversations/#{conversation.display_id}/messages",
           params: { content: 'hello' }

      expect(response).to have_http_status(:success)
      data = response.parsed_body
      expect(data['content']).to eq('hello')
    end

    it 'does not create the message' do
      content = "#{'h' * 150 * 1000}a"
      post "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{contact_inbox.source_id}/conversations/#{conversation.display_id}/messages",
           params: { content: content }

      expect(response).to have_http_status(:unprocessable_entity)

      json_response = response.parsed_body

      expect(json_response['message']).to eq('Content is too long (maximum is 150000 characters)')
    end

    it 'creates attachment message in conversation' do
      file = fixture_file_upload(Rails.root.join('spec/assets/avatar.png'), 'image/png')
      post "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{contact_inbox.source_id}/conversations/#{conversation.display_id}/messages",
           params: { content: 'hello', attachments: [file] }

      expect(response).to have_http_status(:success)
      data = response.parsed_body
      expect(data['content']).to eq('hello')

      expect(conversation.messages.last.attachments.first.file.present?).to be(true)
      expect(conversation.messages.last.attachments.first.file_type).to eq('image')
    end

    # Adalink: clique para o WhatsApp — esta é a API pública de inbox
    # (Public::Api::V1::Inboxes::MessagesController), usada por widgets/
    # integrações externas com uma inbox Channel::Api. NÃO é o caminho que o
    # WhatsApp pessoal (Evolution) usa: a Edge Function wa-pessoal-webhook
    # entrega mensagens pela API DE CONTA
    # (POST /api/v1/accounts/{account_id}/conversations/{conversation_id}/messages,
    # Api::V1::Accounts::Conversations::MessagesController — coberto em
    # spec/controllers/api/v1/accounts/conversations/messages_controller_spec.rb).
    # Ainda assim vale como não-regressão desta API pública: message_params
    # aqui só permite :content e :echo_id (permitted_params), então um campo
    # referral no payload é descartado pelo próprio params.permit antes
    # mesmo de chegar em Message.new — additional_attributes fica vazio, sem
    # nenhum tratamento especial de referral (Channel::Whatsapp e seu
    # Whatsapp::IncomingMessageBaseService/referral_params nunca entram
    # neste fluxo).
    it 'ignores a referral field in the payload on this public inbox API (unrelated to WhatsApp Cloud API or to the real WhatsApp pessoal path)' do
      post "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{contact_inbox.source_id}/conversations/#{conversation.display_id}/messages",
           params: { content: 'hello', referral: { ctwa_clid: 'ShouldBeIgnoredByChannelApi' } }

      expect(response).to have_http_status(:success)
      data = response.parsed_body
      expect(data['content']).to eq('hello')

      created_message = conversation.messages.last
      expect(created_message.additional_attributes).to eq({})
    end
  end

  describe 'PATCH /public/api/v1/inboxes/{identifier}/contact/{source_id}/conversations/{conversation_id}/messages/{id}' do
    it 'updates a message in the conversation' do
      message = create(:message, account: conversation.account, inbox: conversation.inbox, conversation: conversation)
      patch "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{contact_inbox.source_id}/conversations/" \
            "#{conversation.display_id}/messages/#{message.id}",
            params: { submitted_values: [{ title: 'test' }] }

      expect(response).to have_http_status(:success)
      data = response.parsed_body
      expect(data['content_attributes']['submitted_values'].first['title']).to eq 'test'
    end

    it 'updates CSAT survey response for the conversation' do
      message = create(:message, account: conversation.account, inbox: conversation.inbox, conversation: conversation, content_type: 'input_csat')
      # since csat survey is created in async job, we are mocking the creation.
      create(:csat_survey_response, conversation: conversation, message: message, rating: 4, feedback_message: 'amazing experience')

      patch "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{contact_inbox.source_id}/conversations/" \
            "#{conversation.display_id}/messages/#{message.id}",
            params: { submitted_values: { csat_survey_response: { rating: 4, feedback_message: 'amazing experience' } } },
            as: :json

      expect(response).to have_http_status(:success)
      data = response.parsed_body
      expect(data['content_attributes']['submitted_values']['csat_survey_response']['feedback_message']).to eq 'amazing experience'
      expect(data['content_attributes']['submitted_values']['csat_survey_response']['rating']).to eq 4
    end

    it 'returns update error if CSAT message sent more than 14 days' do
      message = create(:message, account: conversation.account, inbox: conversation.inbox, conversation: conversation, content_type: 'input_csat',
                                 created_at: 15.days.ago)
      # since csat survey is created in async job, we are mocking the creation.
      create(:csat_survey_response, conversation: conversation, message: message, rating: 4, feedback_message: 'amazing experience')

      patch "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{contact_inbox.source_id}/conversations/" \
            "#{conversation.display_id}/messages/#{message.id}",
            params: { submitted_values: { csat_survey_response: { rating: 4, feedback_message: 'amazing experience' } } },
            as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
