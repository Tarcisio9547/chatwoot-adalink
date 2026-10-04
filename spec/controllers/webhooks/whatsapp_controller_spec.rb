require 'rails_helper'

RSpec.describe 'Webhooks::WhatsappController', type: :request do
  let(:channel) { create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false) }
  let(:global_secret) { 'test-whatsapp-secret' }
  let(:body) { { content: 'hello' }.to_json }
  let(:signature_header) { 'X-Hub-Signature-256' }

  def signature_for(payload, secret)
    "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, payload)}"
  end

  def post_webhook(path, payload, secret: nil, headers: {})
    request_headers = { 'CONTENT_TYPE' => 'application/json' }.merge(headers)
    request_headers[signature_header] = signature_for(payload, secret) if secret
    post path, params: payload, headers: request_headers
  end

  def business_account_payload(for_channel)
    {
      object: 'whatsapp_business_account',
      entry: [{
        changes: [{
          value: {
            metadata: {
              display_phone_number: for_channel.phone_number.delete_prefix('+'),
              phone_number_id: for_channel.provider_config['phone_number_id']
            }
          }
        }]
      }]
    }.to_json
  end

  # Caixa Cloud criada manualmente no CRM: sem embedded signup e sem app secret no provider_config.
  def manual_cloud_channel
    channel.update!(
      provider_config: channel.provider_config.except('app_secret', 'app_secret_key', 'api_secret', 'client_secret', 'source')
    )
    channel
  end

  def with_channel_secret(target_channel, secret, key: 'app_secret')
    target_channel.update!(provider_config: target_channel.provider_config.merge(key => secret))
    target_channel
  end

  before do
    InstallationConfig.where(name: 'WHATSAPP_APP_SECRET').delete_all
    GlobalConfig.clear_cache
    allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
    allow(Rails.logger).to receive(:warn)
  end

  after { GlobalConfig.clear_cache }

  def expect_job_enqueued
    expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later).once
  end

  def expect_job_not_enqueued
    expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
  end

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
    context 'when no app secret is configured anywhere (channel or global)' do
      it 'accepts an unsigned request, enqueues the job and logs a warning once' do
        post_webhook("/webhooks/whatsapp/#{manual_cloud_channel.phone_number}", business_account_payload(manual_cloud_channel))

        expect(response).to have_http_status(:success)
        expect_job_enqueued
        expect(Rails.logger).to have_received(:warn).with(/nenhum app secret configurado/).once
      end

      it 'accepts an unsigned request for embedded signup cloud channels too' do
        post_webhook("/webhooks/whatsapp/#{channel.phone_number}", business_account_payload(channel))

        expect(response).to have_http_status(:success)
        expect_job_enqueued
        expect(Rails.logger).to have_received(:warn).with(/nenhum app secret configurado/).once
      end

      it 'accepts an unsigned request for an unknown phone number and warns' do
        post_webhook('/webhooks/whatsapp/123221321', body)

        expect(response).to have_http_status(:success)
        expect_job_enqueued
        expect(Rails.logger).to have_received(:warn).with(/nenhum app secret configurado/).once
      end

      it 'treats a blank app secret (empty ENV variable) as not configured and warns' do
        with_modified_env WHATSAPP_APP_SECRET: '' do
          post_webhook('/webhooks/whatsapp/123221321', body)
        end

        expect(response).to have_http_status(:success)
        expect(Rails.logger).to have_received(:warn).with(/nenhum app secret configurado/).once
      end
    end

    context 'when WHATSAPP_APP_SECRET is configured (global secret)' do
      around do |example|
        with_modified_env(WHATSAPP_APP_SECRET: global_secret) { example.run }
      end

      it 'accepts a valid signature for a manual cloud channel without a channel secret' do
        post_webhook("/webhooks/whatsapp/#{manual_cloud_channel.phone_number}", business_account_payload(manual_cloud_channel),
                     secret: global_secret)

        expect(response).to have_http_status(:success)
        expect_job_enqueued
        expect(Rails.logger).not_to have_received(:warn).with(/nenhum app secret configurado/)
      end

      it 'accepts a valid signature for an embedded signup cloud channel' do
        post_webhook("/webhooks/whatsapp/#{channel.phone_number}", business_account_payload(channel), secret: global_secret)

        expect(response).to have_http_status(:success)
        expect_job_enqueued
      end

      it 'accepts a valid signature for an unknown phone number (job drops it later)' do
        post_webhook('/webhooks/whatsapp/123221321', body, secret: global_secret)

        expect(response).to have_http_status(:success)
        expect_job_enqueued
      end

      it 'returns unauthorized when the signature header is missing, even for a manual cloud channel without a channel secret' do
        post_webhook("/webhooks/whatsapp/#{manual_cloud_channel.phone_number}", business_account_payload(manual_cloud_channel))

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
        expect(Rails.logger).to have_received(:warn).with(/rejeitada.*ausente/).once
      end

      it 'returns unauthorized when the signature header is missing for an unknown phone number' do
        post_webhook('/webhooks/whatsapp/123221321', body)

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
      end

      it 'returns unauthorized when the signature is invalid' do
        post_webhook("/webhooks/whatsapp/#{manual_cloud_channel.phone_number}", business_account_payload(manual_cloud_channel),
                     headers: { signature_header => 'sha256=invalid-signature' })

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
        expect(Rails.logger).to have_received(:warn).with(/rejeitada.*invalida/).once
      end

      it 'returns unauthorized when the signature has no sha256= prefix' do
        digest = OpenSSL::HMAC.hexdigest('SHA256', global_secret, body)

        post_webhook('/webhooks/whatsapp/123221321', body, headers: { signature_header => digest })

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
      end

      it 'returns unauthorized when the body was changed after signing' do
        signed_headers = { signature_header => signature_for(body, global_secret) }

        post_webhook('/webhooks/whatsapp/123221321', { content: 'tampered' }.to_json, headers: signed_headers)

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
      end

      it 'returns unauthorized when the request is signed with a different secret' do
        post_webhook("/webhooks/whatsapp/#{manual_cloud_channel.phone_number}", business_account_payload(manual_cloud_channel),
                     secret: 'segredo-de-outro-app')

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
      end

      it 'does not log the "no secret" warning when it rejects the request' do
        post_webhook('/webhooks/whatsapp/123221321', body)

        expect(Rails.logger).not_to have_received(:warn).with(/nenhum app secret configurado/)
      end

      it 'skips signature validation for 360dialog channels' do
        dialog_channel = create(:channel_whatsapp, provider: 'default', sync_templates: false, validate_provider_config: false)

        post_webhook("/webhooks/whatsapp/#{dialog_channel.phone_number}", body)

        expect(response).to have_http_status(:success)
        expect_job_enqueued
        expect(Rails.logger).not_to have_received(:warn).with(/nenhum app secret configurado/)
      end
    end

    context 'when the global secret comes from the installation config' do
      it 'uses the value saved in InstallationConfig (Super Admin)' do
        InstallationConfig.create!(name: 'WHATSAPP_APP_SECRET', value: global_secret, locked: false)
        GlobalConfig.clear_cache

        post_webhook('/webhooks/whatsapp/123221321', body)
        expect(response).to have_http_status(:unauthorized)

        post_webhook('/webhooks/whatsapp/123221321', body, secret: global_secret)
        expect(response).to have_http_status(:success)
      end

      it 'falls back to the ENV variable when the installation config row exists but is blank' do
        # ConfigLoader semeia a linha WHATSAPP_APP_SECRET sem valor; o ENV do Railway precisa continuar valendo.
        InstallationConfig.create!(name: 'WHATSAPP_APP_SECRET', value: nil, locked: false)
        GlobalConfig.clear_cache

        with_modified_env WHATSAPP_APP_SECRET: global_secret do
          post_webhook('/webhooks/whatsapp/123221321', body)
          expect(response).to have_http_status(:unauthorized)

          post_webhook('/webhooks/whatsapp/123221321', body, secret: global_secret)
          expect(response).to have_http_status(:success)
        end
      end
    end

    context 'when the channel has its own app secret' do
      let(:channel_secret) { 'channel-whatsapp-secret' }

      it 'accepts a request signed with the channel secret when no global secret exists' do
        with_channel_secret(channel, channel_secret)

        post_webhook("/webhooks/whatsapp/#{channel.phone_number}", business_account_payload(channel), secret: channel_secret)

        expect(response).to have_http_status(:success)
        expect_job_enqueued
        expect(Rails.logger).not_to have_received(:warn).with(/nenhum app secret configurado/)
      end

      it 'returns unauthorized when the channel has a secret but the request is unsigned and no global secret exists' do
        with_channel_secret(channel, channel_secret)

        post_webhook("/webhooks/whatsapp/#{channel.phone_number}", business_account_payload(channel))

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
      end

      %w[app_secret app_secret_key client_secret api_secret].each do |key|
        it "reads the channel secret from provider_config['#{key}']" do
          with_channel_secret(channel, channel_secret, key: key)

          post_webhook("/webhooks/whatsapp/#{channel.phone_number}", business_account_payload(channel), secret: channel_secret)

          expect(response).to have_http_status(:success)
          expect_job_enqueued
        end
      end

      it 'resolves the channel through the URL phone number when the payload has no business account metadata' do
        with_channel_secret(channel, channel_secret)

        post_webhook("/webhooks/whatsapp/#{channel.phone_number}", body, secret: channel_secret)

        expect(response).to have_http_status(:success)
        expect_job_enqueued
      end

      it 'gives the channel secret priority over the global secret' do
        with_channel_secret(channel, channel_secret)

        with_modified_env WHATSAPP_APP_SECRET: global_secret do
          post_webhook("/webhooks/whatsapp/#{channel.phone_number}", business_account_payload(channel), secret: channel_secret)
          expect(response).to have_http_status(:success)
        end
        expect_job_enqueued
      end

      it 'does not accept the global secret for a channel that has its own secret' do
        with_channel_secret(channel, channel_secret)

        with_modified_env WHATSAPP_APP_SECRET: global_secret do
          post_webhook("/webhooks/whatsapp/#{channel.phone_number}", business_account_payload(channel), secret: global_secret)
        end

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
      end

      it 'still uses the global secret for other cloud channels that have no secret of their own' do
        with_channel_secret(channel, channel_secret)
        other_channel = create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)

        with_modified_env WHATSAPP_APP_SECRET: global_secret do
          post_webhook("/webhooks/whatsapp/#{other_channel.phone_number}", business_account_payload(other_channel), secret: global_secret)
        end

        expect(response).to have_http_status(:success)
        expect_job_enqueued
      end
    end

    context 'when the provider is 360dialog' do
      let(:dialog_channel) { create(:channel_whatsapp, provider: 'default', sync_templates: false, validate_provider_config: false) }

      it 'does not check the signature even with a global secret configured' do
        with_modified_env WHATSAPP_APP_SECRET: global_secret do
          post_webhook("/webhooks/whatsapp/#{dialog_channel.phone_number}", body)
        end

        expect(response).to have_http_status(:success)
        expect_job_enqueued
      end

      it 'does not check the signature when no secret is configured and does not warn' do
        post_webhook("/webhooks/whatsapp/#{dialog_channel.phone_number}", body)

        expect(response).to have_http_status(:success)
        expect_job_enqueued
        expect(Rails.logger).not_to have_received(:warn).with(/nenhum app secret configurado/)
      end
    end

    context 'when phone number is in inactive list' do
      before do
        allow(GlobalConfig).to receive(:get_value).with('INACTIVE_WHATSAPP_NUMBERS').and_return('+1234567890,+9876543210')
      end

      it 'returns service unavailable for inactive phone number in URL params' do
        expect(Rails.logger).to receive(:warn).with('Rejected webhook for inactive WhatsApp number: +1234567890')

        with_modified_env WHATSAPP_APP_SECRET: global_secret do
          post_webhook('/webhooks/whatsapp/+1234567890', body, secret: global_secret)
        end

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['error']).to eq('Inactive WhatsApp number')
      end
    end

    context 'when INACTIVE_WHATSAPP_NUMBERS config is not set' do
      before do
        allow(GlobalConfig).to receive(:get_value).with('INACTIVE_WHATSAPP_NUMBERS').and_return(nil)
      end

      it 'processes the webhook normally' do
        with_modified_env WHATSAPP_APP_SECRET: global_secret do
          post_webhook('/webhooks/whatsapp/+1234567890', body, secret: global_secret)
        end

        expect(response).to have_http_status(:success)
        expect_job_enqueued
      end
    end
  end
end
