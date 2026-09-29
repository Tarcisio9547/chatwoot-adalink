require 'rails_helper'

RSpec.describe 'Webhooks::WhatsappController', type: :request do
  let(:channel) { create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false) }

  describe 'GET /webhooks/verify' do
    it 'returns 401 when valid params are not present' do
      get "/webhooks/whatsapp/#{channel.phone_number}"
      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns 401 when invalid params' do
      get "/webhooks/whatsapp/#{channel.phone_number}",
          params: { 'hub.challenge' => '123456', 'hub.mode' => 'subscribe', 'hub.verify_token' => 'invalid' }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns challenge when valid params' do
      get "/webhooks/whatsapp/#{channel.phone_number}",
          params: { 'hub.challenge' => '123456', 'hub.mode' => 'subscribe', 'hub.verify_token' => channel.provider_config['webhook_verify_token'] }
      expect(response.body).to include '123456'
    end
  end

  describe 'POST /webhooks/whatsapp/{:phone_number}' do
    it 'call the whatsapp events job with the params' do
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
      expect(Webhooks::WhatsappEventsJob).to receive(:perform_later)
      post '/webhooks/whatsapp/123221321', params: { content: 'hello' }
      expect(response).to have_http_status(:success)
    end

    context 'when phone number is in inactive list' do
      before do
        allow(GlobalConfig).to receive(:get_value).with('INACTIVE_WHATSAPP_NUMBERS').and_return('+1234567890,+9876543210')
      end

      it 'returns service unavailable for inactive phone number in URL params' do
        allow(Rails.logger).to receive(:warn)
        expect(Rails.logger).to receive(:warn).with('Rejected webhook for inactive WhatsApp number: +1234567890')

        post '/webhooks/whatsapp/+1234567890', params: { content: 'hello' }
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['error']).to eq('Inactive WhatsApp number')
      end
    end

    context 'when INACTIVE_WHATSAPP_NUMBERS config is not set' do
      before do
        allow(GlobalConfig).to receive(:get_value).with('INACTIVE_WHATSAPP_NUMBERS').and_return(nil)
      end

      it 'processes the webhook normally' do
        allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
        expect(Webhooks::WhatsappEventsJob).to receive(:perform_later)

        post '/webhooks/whatsapp/+1234567890', params: { content: 'hello' }
        expect(response).to have_http_status(:success)
      end
    end

    # Adalink: clique para o WhatsApp — caminho real ponta a ponta. O payload
    # chega como ActionController::Parameters, vira Hash via to_unsafe_hash,
    # é serializado/deserializado pelo ActiveJob (Webhooks::WhatsappEventsJob),
    # roda o serviço de ingestão de verdade e dispara o listener de webhook —
    # nada disso é mockado, para provar que o referral sobrevive a essa
    # travessia inteira e aparece no payload real do message_created.
    context 'when the payload has a referral (click-to-whatsapp ad), end to end via the real job' do
      let(:cloud_channel) do
        create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
      end

      it 'persists the referral and delivers it in the message_created webhook payload' do
        webhook = create(:webhook, inbox: cloud_channel.inbox, account: cloud_channel.account)

        payload = {
          object: 'whatsapp_business_account',
          entry: [{
            changes: [{
              value: {
                metadata: {
                  phone_number_id: cloud_channel.provider_config['phone_number_id'],
                  display_phone_number: cloud_channel.phone_number.delete('+')
                },
                contacts: [{ profile: { name: 'Cliente Real' }, wa_id: '5511977776666' }],
                messages: [{
                  from: '5511977776666',
                  id: 'wamid.END_TO_END_MESSAGE',
                  timestamp: '1770500000',
                  type: 'text',
                  text: { body: 'Olá! Vi seu anúncio de verdade.' },
                  referral: { ctwa_clid: 'EndToEndClid001', source_type: 'ad', headline: 'Promo real' }
                }]
              }
            }]
          }]
        }

        delivered_payloads = []
        allow(WebhookJob).to receive(:perform_later) do |*args|
          delivered_payloads << args
        end

        # message_created é despachado via AsyncDispatcher -> EventDispatcherJob
        # (um segundo job, distinto do Webhooks::WhatsappEventsJob), que é
        # quem de fato aciona o WebhookListener. Sem incluir esse job aqui,
        # o listener nunca roda e WebhookJob.perform_later não é chamado.
        perform_enqueued_jobs(only: [Webhooks::WhatsappEventsJob, EventDispatcherJob]) do
          post "/webhooks/whatsapp/#{cloud_channel.phone_number}", params: payload, as: :json
        end

        expect(response).to have_http_status(:success)

        message = cloud_channel.inbox.messages.last
        expect(message.additional_attributes['referral']['ctwa_clid']).to eq('EndToEndClid001')
        expect(message.conversation.additional_attributes['referral']['ctwa_clid']).to eq('EndToEndClid001')

        message_created_call = delivered_payloads.find { |args| args[2] == :account_webhook && args[1][:event] == 'message_created' }
        expect(message_created_call).to be_present
        delivered_url, delivered_payload, = message_created_call
        expect(delivered_url).to eq(webhook.url)
        expect(delivered_payload[:additional_attributes]['referral']['ctwa_clid']).to eq('EndToEndClid001')
        expect(delivered_payload[:conversation][:additional_attributes]['referral']['ctwa_clid']).to eq('EndToEndClid001')
      end
    end
  end
end
