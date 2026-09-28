require 'rails_helper'

describe Whatsapp::IncomingMessageWhatsappCloudService do
  describe '#perform' do
    after do
      Redis::Alfred.scan_each(match: 'MESSAGE_SOURCE_KEY::*') { |key| Redis::Alfred.delete(key) }
    end

    let!(:whatsapp_channel) { create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false) }
    let(:params) do
      {
        phone_number: whatsapp_channel.phone_number,
        object: 'whatsapp_business_account',
        entry: [{
          changes: [{
            value: {
              contacts: [{ profile: { name: 'Sojan Jose' }, wa_id: '2423423243' }],
              messages: [{
                from: '2423423243',
                image: {
                  id: 'b1c68f38-8734-4ad3-b4a1-ef0c10d683',
                  mime_type: 'image/jpeg',
                  sha256: '29ed500fa64eb55fc19dc4124acb300e5dcca0f822a301ae99944db',
                  caption: 'Check out my product!'
                },
                timestamp: '1664799904', type: 'image'
              }]
            }
          }]
        }]
      }.with_indifferent_access
    end

    context 'when valid attachment message params' do
      it 'creates appropriate conversations, message and contacts' do
        stub_media_url_request
        stub_sample_png_request
        described_class.new(inbox: whatsapp_channel.inbox, params: params).perform
        expect_conversation_created
        expect_contact_name
        expect_message_content
        expect_message_has_attachment
      end

      it 'increments reauthorization count if fetching attachment fails' do
        stub_request(
          :get,
          whatsapp_channel.media_url('b1c68f38-8734-4ad3-b4a1-ef0c10d683')
        ).to_return(
          status: 401
        )

        described_class.new(inbox: whatsapp_channel.inbox, params: params).perform
        expect(whatsapp_channel.inbox.conversations.count).not_to eq(0)
        expect(Contact.all.first.name).to eq('Sojan Jose')
        expect(whatsapp_channel.inbox.messages.first.content).to eq('Check out my product!')
        expect(whatsapp_channel.inbox.messages.first.attachments.present?).to be false
        expect(whatsapp_channel.authorization_error_count).to eq(1)
      end
    end

    context 'when invalid attachment message params' do
      let(:error_params) do
        {
          phone_number: whatsapp_channel.phone_number,
          object: 'whatsapp_business_account',
          entry: [{
            changes: [{
              value: {
                contacts: [{ profile: { name: 'Sojan Jose' }, wa_id: '2423423243' }],
                messages: [{
                  from: '2423423243',
                  image: {
                    id: 'b1c68f38-8734-4ad3-b4a1-ef0c10d683',
                    mime_type: 'image/jpeg',
                    sha256: '29ed500fa64eb55fc19dc4124acb300e5dcca0f822a301ae99944db',
                    caption: 'Check out my product!'
                  },
                  errors: [{
                    code: 400,
                    details: 'Last error was: ServerThrottle. Http request error: HTTP response code said error. See logs for details',
                    title: 'Media download failed: Not retrying as download is not retriable at this time'
                  }],
                  timestamp: '1664799904', type: 'image'
                }]
              }
            }]
          }]
        }.with_indifferent_access
      end

      it 'with attachment errors' do
        described_class.new(inbox: whatsapp_channel.inbox, params: error_params).perform
        expect(whatsapp_channel.inbox.conversations.count).not_to eq(0)
        expect(Contact.all.first.name).to eq('Sojan Jose')
        expect(whatsapp_channel.inbox.messages.count).to eq(0)
      end
    end

    context 'when invalid params' do
      it 'will not throw error' do
        described_class.new(inbox: whatsapp_channel.inbox, params: { phone_number: whatsapp_channel.phone_number,
                                                                     object: 'whatsapp_business_account', entry: {} }).perform
        expect(whatsapp_channel.inbox.conversations.count).to eq(0)
        expect(Contact.all.first).to be_nil
        expect(whatsapp_channel.inbox.messages.count).to eq(0)
      end
    end

    context 'when message is a reply (has context)' do
      let(:reply_params) do
        {
          phone_number: whatsapp_channel.phone_number,
          object: 'whatsapp_business_account',
          entry: [{
            changes: [{
              value: {
                contacts: [{ profile: { name: 'Pranav' }, wa_id: '16503071063' }],
                messages: [{
                  context: {
                    from: '16503071063',
                    id: 'wamid.ORIGINAL_MESSAGE_ID'
                  },
                  from: '16503071063',
                  id: 'wamid.REPLY_MESSAGE_ID',
                  timestamp: '1770407829',
                  text: { body: 'This is a reply' },
                  type: 'text'
                }]
              }
            }]
          }]
        }.with_indifferent_access
      end

      context 'when the original message exists in Chatwoot' do
        it 'sets in_reply_to to reference the existing message' do
          # Create a conversation and the original message that will be replied to first
          contact = create(:contact, phone_number: '+16503071063', account: whatsapp_channel.account)
          contact_inbox = create(:contact_inbox, contact: contact, inbox: whatsapp_channel.inbox, source_id: '16503071063')
          conversation = create(:conversation, contact: contact, inbox: whatsapp_channel.inbox, contact_inbox: contact_inbox)

          original_message = create(:message,
                                    conversation: conversation,
                                    source_id: 'wamid.ORIGINAL_MESSAGE_ID',
                                    content: 'Original message')

          described_class.new(inbox: whatsapp_channel.inbox, params: reply_params).perform

          reply_message = whatsapp_channel.inbox.messages.last
          expect(reply_message.content).to eq('This is a reply')
          expect(reply_message.content_attributes['in_reply_to']).to eq(original_message.id)
          expect(reply_message.content_attributes['in_reply_to_external_id']).to eq('wamid.ORIGINAL_MESSAGE_ID')
        end
      end

      context 'when the original message does not exist in Chatwoot' do
        it 'does not set in_reply_to (discards the reply reference)' do
          described_class.new(inbox: whatsapp_channel.inbox, params: reply_params).perform

          reply_message = whatsapp_channel.inbox.messages.last
          expect(reply_message.content).to eq('This is a reply')
          expect(reply_message.content_attributes['in_reply_to']).to be_nil
          expect(reply_message.content_attributes['in_reply_to_external_id']).to be_nil
        end
      end
    end

    # Adalink: clique para o WhatsApp — anúncio de origem (referral) da Meta
    # https://developers.facebook.com/docs/whatsapp/cloud-api/webhooks/payload-examples#referral-messages
    context 'when message has a referral (click-to-whatsapp ad)' do
      let(:referral_payload) do
        {
          source_url: 'https://fb.me/ad-click-url',
          source_id: '120210000000000',
          source_type: 'ad',
          headline: 'Compre agora',
          body: 'Confira nossos imóveis',
          media_type: 'image',
          image_url: 'https://scontent.xx.fbcdn.net/ad-image.jpg',
          thumbnail_url: 'https://scontent.xx.fbcdn.net/ad-thumb.jpg',
          ctwa_clid: 'AfeXYZ123abc',
          welcome_message: { text: 'Olá! Vi seu anúncio.' }
        }
      end

      let(:referral_params) do
        {
          phone_number: whatsapp_channel.phone_number,
          object: 'whatsapp_business_account',
          entry: [{
            changes: [{
              value: {
                contacts: [{ profile: { name: 'Ana Referral' }, wa_id: '5511988887777' }],
                messages: [{
                  from: '5511988887777',
                  id: 'wamid.REFERRAL_MESSAGE_ID',
                  timestamp: '1770500000',
                  type: 'text',
                  text: { body: 'Olá! Vi seu anúncio.' },
                  referral: referral_payload
                }]
              }
            }]
          }]
        }.with_indifferent_access
      end

      it 'stores the whole referral object in the message additional_attributes' do
        described_class.new(inbox: whatsapp_channel.inbox, params: referral_params).perform

        message = whatsapp_channel.inbox.messages.last
        stored_referral = message.additional_attributes['referral']

        expect(stored_referral).to eq(
          'source_url' => 'https://fb.me/ad-click-url',
          'source_id' => '120210000000000',
          'source_type' => 'ad',
          'headline' => 'Compre agora',
          'body' => 'Confira nossos imóveis',
          'media_type' => 'image',
          'image_url' => 'https://scontent.xx.fbcdn.net/ad-image.jpg',
          'thumbnail_url' => 'https://scontent.xx.fbcdn.net/ad-thumb.jpg',
          'ctwa_clid' => 'AfeXYZ123abc',
          'welcome_message' => { 'text' => 'Olá! Vi seu anúncio.' }
        )
      end

      it 'stores the referral object in the additional_attributes of the conversation created by that message' do
        described_class.new(inbox: whatsapp_channel.inbox, params: referral_params).perform

        conversation = whatsapp_channel.inbox.conversations.last
        expect(conversation.additional_attributes['referral']).to be_present
        expect(conversation.additional_attributes['referral']['ctwa_clid']).to eq('AfeXYZ123abc')
      end

      it 'includes the referral object in the message_created webhook payload' do
        described_class.new(inbox: whatsapp_channel.inbox, params: referral_params).perform

        message = whatsapp_channel.inbox.messages.last
        payload = message.webhook_data

        expect(payload[:additional_attributes]['referral']['ctwa_clid']).to eq('AfeXYZ123abc')
        expect(payload[:conversation][:additional_attributes]['referral']['ctwa_clid']).to eq('AfeXYZ123abc')
      end

      it 'does not duplicate the referral on the conversation for a follow-up message without referral' do
        described_class.new(inbox: whatsapp_channel.inbox, params: referral_params).perform
        conversation = whatsapp_channel.inbox.conversations.last
        expect(conversation.additional_attributes['referral']).to be_present

        follow_up_params = {
          phone_number: whatsapp_channel.phone_number,
          object: 'whatsapp_business_account',
          entry: [{
            changes: [{
              value: {
                contacts: [{ profile: { name: 'Ana Referral' }, wa_id: '5511988887777' }],
                messages: [{
                  from: '5511988887777',
                  id: 'wamid.FOLLOWUP_MESSAGE_ID',
                  timestamp: '1770500100',
                  type: 'text',
                  text: { body: 'Qual o valor?' }
                }]
              }
            }]
          }]
        }.with_indifferent_access

        described_class.new(inbox: whatsapp_channel.inbox, params: follow_up_params).perform

        expect(whatsapp_channel.inbox.conversations.count).to eq(1)
        follow_up_message = whatsapp_channel.inbox.messages.last
        expect(follow_up_message.content).to eq('Qual o valor?')
        expect(follow_up_message.additional_attributes['referral']).to be_blank
        # a conversa mantém o referral do anúncio que a originou
        expect(conversation.reload.additional_attributes['referral']['ctwa_clid']).to eq('AfeXYZ123abc')
      end
    end

    # Adalink: mensagem sem referral não pode ganhar a chave à toa (regressão)
    context 'when message has no referral' do
      it 'does not add a referral key to message or conversation additional_attributes' do
        stub_media_url_request
        stub_sample_png_request
        described_class.new(inbox: whatsapp_channel.inbox, params: params).perform

        message = whatsapp_channel.inbox.messages.last
        conversation = whatsapp_channel.inbox.conversations.last
        expect(message.additional_attributes.key?('referral')).to be false
        expect(conversation.additional_attributes.key?('referral')).to be false
      end
    end
  end

  # Métodos auxiliares para reduzir o tamanho do exemplo

  def stub_media_url_request
    stub_request(
      :get,
      whatsapp_channel.media_url('b1c68f38-8734-4ad3-b4a1-ef0c10d683')
    ).to_return(
      status: 200,
      body: {
        messaging_product: 'whatsapp',
        url: 'https://chatwoot-assets.local/sample.png',
        mime_type: 'image/jpeg',
        sha256: 'sha256',
        file_size: 'SIZE',
        id: 'b1c68f38-8734-4ad3-b4a1-ef0c10d683'
      }.to_json,
      headers: { 'content-type' => 'application/json' }
    )
  end

  def stub_sample_png_request
    stub_request(:get, 'https://chatwoot-assets.local/sample.png').to_return(
      status: 200,
      body: File.read('spec/assets/sample.png')
    )
  end

  def expect_conversation_created
    expect(whatsapp_channel.inbox.conversations.count).not_to eq(0)
  end

  def expect_contact_name
    expect(Contact.all.first.name).to eq('Sojan Jose')
  end

  def expect_message_content
    expect(whatsapp_channel.inbox.messages.first.content).to eq('Check out my product!')
  end

  def expect_message_has_attachment
    expect(whatsapp_channel.inbox.messages.first.attachments.present?).to be true
  end
end
