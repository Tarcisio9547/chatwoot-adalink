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
          media_type: 'video',
          image_url: 'https://scontent.xx.fbcdn.net/ad-image.jpg',
          video_url: 'https://scontent.xx.fbcdn.net/ad-video.mp4',
          thumbnail_url: 'https://scontent.xx.fbcdn.net/ad-thumb.jpg',
          ctwa_clid: 'AfeXYZ123abc',
          welcome_message: { text: 'Olá! Vi seu anúncio.' },
          # Adalink: campo hipotético que a Meta ainda não documentou — deve ir
          # inteiro junto, sem allowlist de chaves.
          future_unknown_field: 'valor futuro qualquer'
        }
      end
      let(:referral_params) { build_referral_message_params(referral: referral_payload) }

      def build_referral_message(wa_id:, message_id:, body:, referral:, include_referral:)
        message = {
          from: wa_id,
          id: message_id,
          timestamp: '1770500000',
          type: 'text',
          text: { body: body }
        }
        message[:referral] = referral if include_referral
        message
      end

      # include_referral: false simula o payload real da Meta, que nunca manda
      # a chave "referral" quando não há anúncio (nunca manda referral: null).
      def build_referral_message_params(referral: nil, include_referral: true,
                                        message_id: 'wamid.REFERRAL_MESSAGE_ID',
                                        wa_id: '5511988887777', body: 'Olá! Vi seu anúncio.')
        message = build_referral_message(wa_id: wa_id, message_id: message_id, body: body,
                                         referral: referral, include_referral: include_referral)

        {
          phone_number: whatsapp_channel.phone_number,
          object: 'whatsapp_business_account',
          entry: [{
            changes: [{
              value: {
                contacts: [{ profile: { name: 'Ana Referral' }, wa_id: wa_id }],
                messages: [message]
              }
            }]
          }]
        }.with_indifferent_access
      end

      it 'stores the whole referral object in the message additional_attributes, including unknown fields' do
        described_class.new(inbox: whatsapp_channel.inbox, params: referral_params).perform

        message = whatsapp_channel.inbox.messages.last
        stored_referral = message.additional_attributes['referral']

        expect(stored_referral).to eq(
          'source_url' => 'https://fb.me/ad-click-url',
          'source_id' => '120210000000000',
          'source_type' => 'ad',
          'headline' => 'Compre agora',
          'body' => 'Confira nossos imóveis',
          'media_type' => 'video',
          'image_url' => 'https://scontent.xx.fbcdn.net/ad-image.jpg',
          'video_url' => 'https://scontent.xx.fbcdn.net/ad-video.mp4',
          'thumbnail_url' => 'https://scontent.xx.fbcdn.net/ad-thumb.jpg',
          'ctwa_clid' => 'AfeXYZ123abc',
          'welcome_message' => { 'text' => 'Olá! Vi seu anúncio.' },
          'future_unknown_field' => 'valor futuro qualquer'
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

      # A conversa nasce JÁ com o referral (via conversation_params), sem um
      # segundo save! só para isso depois de criada. Um UPDATE extra tocando
      # additional_attributes dispararia after_update_commit
      # (handle_resolved_status_change, notify_status_change, create_activity,
      # CONVERSATION_UPDATED) para uma conversa que acabou de nascer — side
      # effect indevido. (Message já gera 1 UPDATE legítimo e pré-existente em
      # conversations, para last_activity_at/updated_at via
      # set_conversation_activity — não é esse que estamos vigiando aqui.)
      it 'creates the conversation with a single persistence call already carrying the referral' do
        additional_attributes_updates = 0
        subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
          event = ActiveSupport::Notifications::Event.new(*args)
          sql = event.payload[:sql].to_s
          next unless sql.match?(/\AUPDATE\s+"?conversations"?\s/i)

          additional_attributes_updates += 1 if sql.include?('additional_attributes')
        end

        begin
          described_class.new(inbox: whatsapp_channel.inbox, params: referral_params).perform
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end

        expect(additional_attributes_updates).to eq(0)

        conversation = whatsapp_channel.inbox.conversations.last
        expect(conversation.additional_attributes['referral']['ctwa_clid']).to eq('AfeXYZ123abc')
      end

      it 'keeps the referral on the conversation unchanged when a follow-up message has no referral' do
        described_class.new(inbox: whatsapp_channel.inbox, params: referral_params).perform
        conversation = whatsapp_channel.inbox.conversations.last
        expect(conversation.additional_attributes['referral']).to be_present

        follow_up_params = build_referral_message_params(
          include_referral: false, message_id: 'wamid.FOLLOWUP_MESSAGE_ID', body: 'Qual o valor?'
        )

        described_class.new(inbox: whatsapp_channel.inbox, params: follow_up_params).perform

        expect(whatsapp_channel.inbox.conversations.count).to eq(1)
        follow_up_message = whatsapp_channel.inbox.messages.last
        expect(follow_up_message.content).to eq('Qual o valor?')
        expect(follow_up_message.additional_attributes).to eq({})
        # a conversa mantém o referral do anúncio que a originou
        expect(conversation.reload.additional_attributes['referral']['ctwa_clid']).to eq('AfeXYZ123abc')
      end

      # Um segundo clique (outro anúncio) numa conversa JÁ existente grava o
      # novo referral só na mensagem; o referral da conversa (o do anúncio
      # que a criou) não é sobrescrito.
      it 'stores a different referral only on the message for a second click on an existing conversation' do
        described_class.new(inbox: whatsapp_channel.inbox, params: referral_params).perform
        conversation = whatsapp_channel.inbox.conversations.last
        original_conversation_referral = conversation.additional_attributes['referral']

        second_click_referral = referral_payload.merge(ctwa_clid: 'SecondClickClid999', headline: 'Outro anúncio')
        second_click_params = build_referral_message_params(
          referral: second_click_referral, message_id: 'wamid.SECOND_CLICK_MESSAGE_ID', body: 'Vi outro anúncio agora'
        )

        described_class.new(inbox: whatsapp_channel.inbox, params: second_click_params).perform

        expect(whatsapp_channel.inbox.conversations.count).to eq(1)
        second_click_message = whatsapp_channel.inbox.messages.last
        expect(second_click_message.additional_attributes['referral']['ctwa_clid']).to eq('SecondClickClid999')
        expect(conversation.reload.additional_attributes['referral']).to eq(original_conversation_referral)
      end

      # Referral malformado (não-Hash) nunca pode derrubar a gravação da
      # mensagem. Uma string >1500 chars fazia @conversation.save! estourar
      # JsonbAttributesLengthValidator e a mensagem se perder.
      context 'when referral is malformed' do
        it 'ignores an overly long string referral and still saves the message' do
          long_string_params = build_referral_message_params(referral: 'x' * 2000)

          expect { described_class.new(inbox: whatsapp_channel.inbox, params: long_string_params).perform }
            .not_to raise_error

          expect(whatsapp_channel.inbox.conversations.count).to eq(1)
          message = whatsapp_channel.inbox.messages.last
          expect(message.content).to eq('Olá! Vi seu anúncio.')
          expect(message.additional_attributes).to eq({})
          conversation = whatsapp_channel.inbox.conversations.last
          expect(conversation.additional_attributes).to eq({})
        end

        it 'ignores an array referral and still saves the message' do
          array_params = build_referral_message_params(referral: %w[not a hash])

          expect { described_class.new(inbox: whatsapp_channel.inbox, params: array_params).perform }
            .not_to raise_error

          message = whatsapp_channel.inbox.messages.last
          expect(message.content).to eq('Olá! Vi seu anúncio.')
          expect(message.additional_attributes).to eq({})
        end

        it 'ignores a nil referral and still saves the message' do
          nil_params = build_referral_message_params(referral: nil)

          expect { described_class.new(inbox: whatsapp_channel.inbox, params: nil_params).perform }
            .not_to raise_error

          message = whatsapp_channel.inbox.messages.last
          expect(message.content).to eq('Olá! Vi seu anúncio.')
          expect(message.additional_attributes).to eq({})
        end

        # O Postgres recusa INSERT em texto/jsonb com o byte NUL (\u0000):
        # PG::UntranslatableCharacter. Sem tratamento, isso derrubava
        # @message.save! inteiro — e como a trava de duplicidade (Redis, 1
        # dia) já tinha sido setada antes da transação falhar, o retry do
        # Sidekiq via visibility timeout também batia na trava e descartava
        # o evento em silêncio, perdendo a mensagem definitivamente.
        it 'strips NUL bytes from referral fields (including nested ones) and still saves the message' do
          referral_with_nul = referral_payload.merge(
            ctwa_clid: "Afe\u0000XYZ123abc",
            headline: "Compre\u0000 agora",
            welcome_message: { text: "Olá!\u0000 Vi seu anúncio." }
          )
          nul_params = build_referral_message_params(referral: referral_with_nul)

          expect { described_class.new(inbox: whatsapp_channel.inbox, params: nul_params).perform }
            .not_to raise_error

          message = whatsapp_channel.inbox.messages.last
          stored_referral = message.additional_attributes['referral']
          expect(stored_referral['ctwa_clid']).to eq('AfeXYZ123abc')
          expect(stored_referral['headline']).to eq('Compre agora')
          expect(stored_referral['welcome_message']['text']).to eq('Olá! Vi seu anúncio.')

          conversation = whatsapp_channel.inbox.conversations.last
          expect(conversation.additional_attributes['referral']['ctwa_clid']).to eq('AfeXYZ123abc')
        end

        # Texto longo DENTRO do Hash (não o referral inteiro sendo uma
        # string) precisa ser gravado sem problema — o limite de 1500 chars
        # do JsonbAttributesLengthValidator vale para valores de nível 1 de
        # additional_attributes (o campo 'referral' vira um Hash, não uma
        # string), então um body de 5000 chars ou muitas chaves não deveria
        # nem tocar essa validação.
        it 'saves the message with a long text field and many keys nested inside the referral hash' do
          long_body = 'a' * 5000
          many_keys_referral = referral_payload.merge(body: long_body)
          (1..50).each { |n| many_keys_referral["extra_field_#{n}"] = "valor #{n}" }
          long_referral_params = build_referral_message_params(referral: many_keys_referral)

          expect { described_class.new(inbox: whatsapp_channel.inbox, params: long_referral_params).perform }
            .not_to raise_error

          message = whatsapp_channel.inbox.messages.last
          stored_referral = message.additional_attributes['referral']
          expect(stored_referral['body']).to eq(long_body)
          expect(stored_referral['extra_field_50']).to eq('valor 50')
          expect(stored_referral.keys.size).to eq(many_keys_referral.keys.size)
        end
      end

      # A mensagem-mãe do tipo 'contacts' (compartilhamento de contato) não
      # tem 'referral' — o referral vem sempre do objeto messages_data.first
      # (a mensagem raiz do payload). create_message é chamado uma vez por
      # contato compartilhado, então sem ler da raiz o referral se perdia.
      context 'when message type is contacts' do
        let(:contacts_referral_params) do
          {
            phone_number: whatsapp_channel.phone_number,
            object: 'whatsapp_business_account',
            entry: [{
              changes: [{
                value: {
                  contacts: [{ profile: { name: 'Ana Referral' }, wa_id: '5511988887777' }],
                  messages: [{
                    from: '5511988887777',
                    id: 'wamid.CONTACTS_TYPE_MESSAGE',
                    timestamp: '1770500000',
                    type: 'contacts',
                    referral: referral_payload,
                    contacts: [{
                      name: { first_name: 'Fulano', last_name: 'Silva' },
                      phones: [{ phone: '+5511911112222' }]
                    }]
                  }]
                }
              }]
            }]
          }.with_indifferent_access
        end

        it 'stores the referral on the message and on the newly created conversation' do
          described_class.new(inbox: whatsapp_channel.inbox, params: contacts_referral_params).perform

          message = whatsapp_channel.inbox.messages.last
          expect(message.additional_attributes['referral']['ctwa_clid']).to eq('AfeXYZ123abc')

          conversation = whatsapp_channel.inbox.conversations.last
          expect(conversation.additional_attributes['referral']['ctwa_clid']).to eq('AfeXYZ123abc')
        end

        it 'stores the referral on the message when the conversation already exists' do
          contact_inbox = create(:contact_inbox, inbox: whatsapp_channel.inbox, source_id: '5511988887777')
          existing_conversation = create(:conversation, inbox: whatsapp_channel.inbox, contact_inbox: contact_inbox)

          described_class.new(inbox: whatsapp_channel.inbox, params: contacts_referral_params).perform

          expect(whatsapp_channel.inbox.conversations.count).to eq(1)
          message = whatsapp_channel.inbox.messages.last
          expect(message.additional_attributes['referral']['ctwa_clid']).to eq('AfeXYZ123abc')
          # a conversa já existia antes do clique, então ela não é reescrita com o referral
          expect(existing_conversation.reload.additional_attributes['referral']).to be_nil
        end
      end
    end

    # Adalink: mensagem sem referral não pode ganhar a chave à toa (regressão)
    context 'when message has no referral' do
      it 'leaves additional_attributes empty on message and conversation' do
        stub_media_url_request
        stub_sample_png_request
        described_class.new(inbox: whatsapp_channel.inbox, params: params).perform

        message = whatsapp_channel.inbox.messages.last
        conversation = whatsapp_channel.inbox.conversations.last
        expect(message.additional_attributes).to eq({})
        expect(conversation.additional_attributes).to eq({})
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
