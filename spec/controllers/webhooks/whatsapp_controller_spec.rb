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
    MetaWebhook::UnverifiedWarningThrottle.reset!
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
      it 'accepts an unsigned request, enqueues the job and logs a warning' do
        post_webhook("/webhooks/whatsapp/#{manual_cloud_channel.phone_number}", business_account_payload(manual_cloud_channel))

        expect(response).to have_http_status(:success)
        expect_job_enqueued
        expect(Rails.logger).to have_received(:warn).with(/nenhum app secret configurado/).once
      end

      it 'logs the warning at most once per hour per process and reports how many requests were accepted in between' do
        3.times { post_webhook('/webhooks/whatsapp/123221321', body) }

        expect(Rails.logger).to have_received(:warn).with(/nenhum app secret configurado.*desde o ultimo aviso: 1\b/).once

        travel 61.minutes do
          post_webhook('/webhooks/whatsapp/123221321', body)
        end

        expect(Rails.logger).to have_received(:warn).with(/nenhum app secret configurado.*desde o ultimo aviso: 3\b/).once
        expect(Rails.logger).to have_received(:warn).with(/nenhum app secret configurado/).twice
        expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later).exactly(4).times
      end

      it 'does not throttle across a request that is still inside the hour' do
        post_webhook('/webhooks/whatsapp/123221321', body)

        travel 59.minutes do
          post_webhook('/webhooks/whatsapp/123221321', body)
        end

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

    context 'when META_WEBHOOK_REQUIRE_SIGNATURE is on and no secret is configured' do
      around do |example|
        with_modified_env(META_WEBHOOK_REQUIRE_SIGNATURE: 'true') { example.run }
      end

      it 'returns unauthorized for a manual cloud channel and does not enqueue' do
        post_webhook("/webhooks/whatsapp/#{manual_cloud_channel.phone_number}", business_account_payload(manual_cloud_channel))

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
        expect(Rails.logger).to have_received(:warn).with(/rejeitada.*nenhum app secret configurado.*META_WEBHOOK_REQUIRE_SIGNATURE/).once
      end

      it 'returns unauthorized for an embedded signup cloud channel' do
        post_webhook("/webhooks/whatsapp/#{channel.phone_number}", business_account_payload(channel))

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
      end

      it 'returns unauthorized for an unknown phone number' do
        post_webhook('/webhooks/whatsapp/123221321', body)

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
      end

      it 'returns unauthorized even when the request carries a signature, since there is no secret to compare' do
        post_webhook('/webhooks/whatsapp/123221321', body, secret: 'qualquer-segredo')

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
      end

      it 'does not emit the throttled "accepted without checking" warning' do
        post_webhook('/webhooks/whatsapp/123221321', body)

        expect(Rails.logger).not_to have_received(:warn).with(/NAO conferida/)
      end

      it 'still skips 360dialog channels' do
        dialog_channel = create(:channel_whatsapp, provider: 'default', sync_templates: false, validate_provider_config: false)

        post_webhook("/webhooks/whatsapp/#{dialog_channel.phone_number}", body)

        expect(response).to have_http_status(:success)
        expect_job_enqueued
      end

      it 'accepts a valid signature once a secret is configured' do
        with_modified_env WHATSAPP_APP_SECRET: global_secret do
          post_webhook('/webhooks/whatsapp/123221321', body, secret: global_secret)
        end

        expect(response).to have_http_status(:success)
        expect_job_enqueued
      end
    end

    context 'when META_WEBHOOK_REQUIRE_SIGNATURE is off or has an unknown value' do
      ['false', '0', 'no', '', 'talvez'].each do |value|
        it "keeps accepting requests without a secret when the flag is #{value.inspect}" do
          with_modified_env META_WEBHOOK_REQUIRE_SIGNATURE: value do
            post_webhook('/webhooks/whatsapp/123221321', body)
          end

          expect(response).to have_http_status(:success)
          expect_job_enqueued
        end
      end
    end

    context 'when trying to bypass the signature check' do
      let(:channel_a_secret) { 'segredo-da-caixa-a' }
      let(:channel_b_secret) { 'segredo-da-caixa-b' }
      let(:dialog_channel) { create(:channel_whatsapp, provider: 'default', sync_templates: false, validate_provider_config: false) }

      it 'rejects a Cloud payload posted to the URL of a 360dialog channel when the metadata matches a Cloud channel' do
        with_modified_env WHATSAPP_APP_SECRET: global_secret do
          post_webhook("/webhooks/whatsapp/#{dialog_channel.phone_number}", business_account_payload(channel))
        end

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
      end

      it 'accepts that same Cloud payload on the 360dialog URL only with a valid signature' do
        with_modified_env WHATSAPP_APP_SECRET: global_secret do
          post_webhook("/webhooks/whatsapp/#{dialog_channel.phone_number}", business_account_payload(channel), secret: global_secret)
        end

        expect(response).to have_http_status(:success)
        expect_job_enqueued
      end

      it 'rejects a payload for channel A signed with the secret of channel B' do
        other_channel = create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
        with_channel_secret(channel, channel_a_secret)
        with_channel_secret(other_channel, channel_b_secret)

        post_webhook("/webhooks/whatsapp/#{channel.phone_number}", business_account_payload(channel), secret: channel_b_secret)

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
      end

      it 'rejects a payload for channel A posted to the URL of channel B and signed with the secret of B' do
        other_channel = create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
        with_channel_secret(channel, channel_a_secret)
        with_channel_secret(other_channel, channel_b_secret)

        post_webhook("/webhooks/whatsapp/#{other_channel.phone_number}", business_account_payload(channel), secret: channel_b_secret)

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
      end

      it 'does not let query string parameters reach the job' do
        enqueued = nil
        allow(Webhooks::WhatsappEventsJob).to receive(:perform_later) { |args| enqueued = args }

        with_modified_env WHATSAPP_APP_SECRET: global_secret do
          post_webhook("/webhooks/whatsapp/#{channel.phone_number}?injected=1&object=whatsapp_business_account",
                       { messages: [] }.to_json, secret: global_secret)
        end

        expect(response).to have_http_status(:success)
        expect(enqueued.keys).to match_array(%w[messages phone_number])
        expect(enqueued['phone_number']).to eq(channel.phone_number)
      end

      it 'does not let a query string object turn a 360dialog request into a Cloud payload' do
        # object na query não vale: a decisão (e o que vai para o job) sai só do corpo
        dialog_url = "/webhooks/whatsapp/#{dialog_channel.phone_number}?object=whatsapp_business_account"

        with_modified_env WHATSAPP_APP_SECRET: global_secret do
          post_webhook(dialog_url, { messages: [] }.to_json)
        end

        expect(response).to have_http_status(:success)
        expect_job_enqueued
      end
    end

    context 'when looking at the payload that reaches the job' do
      it 'keeps the same format as before: indifferent access hash with the body keys plus the route phone number' do
        enqueued = nil
        allow(Webhooks::WhatsappEventsJob).to receive(:perform_later) { |args| enqueued = args }
        payload = business_account_payload(channel)

        with_modified_env WHATSAPP_APP_SECRET: global_secret do
          post_webhook("/webhooks/whatsapp/#{channel.phone_number}", payload, secret: global_secret)
        end

        expect(enqueued).to be_a(ActiveSupport::HashWithIndifferentAccess)
        expect(enqueued[:object]).to eq('whatsapp_business_account')
        expect(enqueued.dig(:entry, 0, :changes, 0, :value, :metadata, :phone_number_id)).to eq(channel.provider_config['phone_number_id'])
        expect(enqueued[:phone_number]).to eq(channel.phone_number)
        expect(enqueued.keys).to match_array(%w[object entry phone_number])
      end

      it 'runs the real job end to end with the enqueued arguments' do
        service = instance_double(Whatsapp::IncomingMessageWhatsappCloudService, perform: true)
        received_params = nil
        allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new) do |params:, **|
          received_params = params
          service
        end
        allow(Webhooks::WhatsappEventsJob).to receive(:perform_later).and_call_original

        with_modified_env WHATSAPP_APP_SECRET: global_secret do
          perform_enqueued_jobs do
            post_webhook("/webhooks/whatsapp/#{channel.phone_number}?injected=1", business_account_payload(channel), secret: global_secret)
          end
        end

        expect(response).to have_http_status(:success)
        expect(service).to have_received(:perform)
        expect(received_params[:object]).to eq('whatsapp_business_account')
        expect(received_params[:phone_number]).to eq(channel.phone_number)
        expect(received_params.keys).not_to include('injected', 'controller', 'action')
      end

      it 'survives the ActiveJob serialization keeping indifferent access' do
        enqueued = nil
        allow(Webhooks::WhatsappEventsJob).to receive(:perform_later) { |args| enqueued = args }

        with_modified_env WHATSAPP_APP_SECRET: global_secret do
          post_webhook("/webhooks/whatsapp/#{channel.phone_number}", business_account_payload(channel), secret: global_secret)
        end

        round_trip = ActiveJob::Arguments.deserialize(ActiveJob::Arguments.serialize([enqueued])).first
        expect(round_trip[:object]).to eq('whatsapp_business_account')
        expect(round_trip.dig(:entry, 0, :changes, 0, :value, :metadata, :display_phone_number)).to eq(channel.phone_number.delete_prefix('+'))
        expect(round_trip[:phone_number]).to eq(channel.phone_number)
      end
    end

    context 'when the payload is malformed' do
      let(:malformed_bodies) do
        {
          'metadata as a string' => { object: 'whatsapp_business_account', entry: [{ changes: [{ value: { metadata: 'texto' } }] }] },
          'value as a string' => { object: 'whatsapp_business_account', entry: [{ changes: [{ value: 'texto' }] }] },
          'entry as an object' => { object: 'whatsapp_business_account', entry: { changes: [] } },
          'entry as a string' => { object: 'whatsapp_business_account', entry: 'texto' },
          'changes as an object' => { object: 'whatsapp_business_account', entry: [{ changes: { value: {} } }] },
          'entry items as numbers' => { object: 'whatsapp_business_account', entry: [1, 2, 3] },
          'object as an array' => { object: ['whatsapp_business_account'], entry: [] }
        }
      end

      it 'answers 401 instead of 500 when a secret is configured and the request is unsigned' do
        with_modified_env WHATSAPP_APP_SECRET: global_secret do
          malformed_bodies.each do |label, malformed|
            post_webhook("/webhooks/whatsapp/#{channel.phone_number}", malformed.to_json)

            expect(response.status).to eq(401), "expected 401 for #{label}, got #{response.status}"
          end
        end
        expect_job_not_enqueued
      end

      it 'does not answer 5xx when no secret is configured' do
        malformed_bodies.each do |label, malformed|
          post_webhook("/webhooks/whatsapp/#{channel.phone_number}", malformed.to_json)

          expect(response.status).to be < 500, "expected no 5xx for #{label}, got #{response.status}"
        end
      end

      it 'does not answer 5xx when the request is properly signed' do
        with_modified_env WHATSAPP_APP_SECRET: global_secret do
          malformed_bodies.each do |label, malformed|
            post_webhook("/webhooks/whatsapp/#{channel.phone_number}", malformed.to_json, secret: global_secret)

            expect(response.status).to be < 500, "expected no 5xx for #{label}, got #{response.status}"
          end
        end
      end

      it 'answers 400 for a JSON body that is not an object, once the signature is valid' do
        with_modified_env WHATSAPP_APP_SECRET: global_secret do
          post_webhook("/webhooks/whatsapp/#{channel.phone_number}", [1, 2].to_json, secret: global_secret)
        end

        expect(response).to have_http_status(:bad_request)
        expect_job_not_enqueued
      end

      it 'answers 401 for a JSON body that is not an object when the request is unsigned' do
        with_modified_env WHATSAPP_APP_SECRET: global_secret do
          post_webhook("/webhooks/whatsapp/#{channel.phone_number}", [1, 2].to_json)
        end

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
      end
    end

    context 'when a secret has surrounding whitespace' do
      it 'strips the channel secret before comparing, like the global one' do
        with_channel_secret(channel, "  channel-whatsapp-secret\n")

        post_webhook("/webhooks/whatsapp/#{channel.phone_number}", business_account_payload(channel), secret: 'channel-whatsapp-secret')

        expect(response).to have_http_status(:success)
        expect_job_enqueued
      end

      it 'strips the global secret too' do
        with_modified_env WHATSAPP_APP_SECRET: " #{global_secret}\n" do
          post_webhook('/webhooks/whatsapp/123221321', body, secret: global_secret)
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
