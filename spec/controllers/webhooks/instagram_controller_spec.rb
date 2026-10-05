require 'rails_helper'

RSpec.describe 'Webhooks::InstagramController', type: :request do
  let(:instagram_secret) { 'test-instagram-secret' }
  let(:facebook_secret) { 'test-facebook-secret' }
  let(:signature_header) { 'X-Hub-Signature-256' }

  def signature_for(payload, secret)
    "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, payload)}"
  end

  def post_instagram_webhook(payload, secret: nil, headers: {})
    request_headers = { 'CONTENT_TYPE' => 'application/json' }.merge(headers)
    request_headers[signature_header] = signature_for(payload, secret) if secret
    post '/webhooks/instagram', params: payload, headers: request_headers
  end

  before do
    InstallationConfig.where(name: %w[FB_APP_SECRET IG_VERIFY_TOKEN INSTAGRAM_APP_SECRET INSTAGRAM_VERIFY_TOKEN]).delete_all
    GlobalConfig.clear_cache
    MetaWebhook::UnverifiedWarningThrottle.reset!
    allow(Webhooks::InstagramEventsJob).to receive(:perform_later)
    allow(Rails.logger).to receive(:warn)
  end

  after { GlobalConfig.clear_cache }

  def expect_job_enqueued
    expect(Webhooks::InstagramEventsJob).to have_received(:perform_later).once
  end

  def expect_job_not_enqueued
    expect(Webhooks::InstagramEventsJob).not_to have_received(:perform_later)
  end

  describe 'GET /webhooks/verify' do
    it 'returns 401 when valid params are not present' do
      get '/webhooks/instagram/verify'
      expect(response).to have_http_status(:not_found)
    end

    it 'returns 401 when invalid params' do
      with_modified_env IG_VERIFY_TOKEN: '123456' do
        get '/webhooks/instagram/verify', params: { 'hub.challenge' => '123456', 'hub.mode' => 'subscribe', 'hub.verify_token' => 'invalid' }
        expect(response).to have_http_status(:not_found)
      end
    end

    it 'returns challenge when valid params' do
      with_modified_env IG_VERIFY_TOKEN: '123456' do
        get '/webhooks/instagram/verify', params: { 'hub.challenge' => '123456', 'hub.mode' => 'subscribe', 'hub.verify_token' => '123456' }
        expect(response.body).to include '123456'
      end
    end
  end

  describe 'POST /webhooks/instagram' do
    let!(:dm_params) { build(:instagram_message_create_event).with_indifferent_access }
    let(:body) { dm_params.merge(object: 'instagram').to_json }

    context 'when no global app secret is configured' do
      it 'accepts an unsigned request, enqueues the job and logs a warning once' do
        post_instagram_webhook(body)

        expect(response).to have_http_status(:success)
        expect_job_enqueued
        expect(Rails.logger).to have_received(:warn).with(/nenhum app secret configurado/).once
      end

      it 'logs the warning at most once per hour per process and reports how many requests were accepted in between' do
        3.times { post_instagram_webhook(body) }

        expect(Rails.logger).to have_received(:warn).with(/nenhum app secret configurado.*desde o ultimo aviso: 1\b/).once

        travel 61.minutes do
          post_instagram_webhook(body)
        end

        expect(Rails.logger).to have_received(:warn).with(/nenhum app secret configurado.*desde o ultimo aviso: 3\b/).once
        expect(Rails.logger).to have_received(:warn).with(/nenhum app secret configurado/).twice
        expect(Webhooks::InstagramEventsJob).to have_received(:perform_later).exactly(4).times
      end

      it 'accepts a request with a bogus signature header, since there is nothing to compare against' do
        post_instagram_webhook(body, headers: { signature_header => 'sha256=invalid-signature' })

        expect(response).to have_http_status(:success)
        expect_job_enqueued
        expect(Rails.logger).to have_received(:warn).with(/nenhum app secret configurado/).once
      end

      it 'treats blank secrets (empty ENV variables) as not configured and warns' do
        with_modified_env INSTAGRAM_APP_SECRET: '', FB_APP_SECRET: '' do
          post_instagram_webhook(body)
        end

        expect(response).to have_http_status(:success)
        expect_job_enqueued
        expect(Rails.logger).to have_received(:warn).with(/nenhum app secret configurado/).once
      end
    end

    context 'when INSTAGRAM_APP_SECRET is configured' do
      around do |example|
        with_modified_env(INSTAGRAM_APP_SECRET: instagram_secret) { example.run }
      end

      it 'calls the instagram events job with the params for a valid signature' do
        post_instagram_webhook(body, secret: instagram_secret)

        expect(response).to have_http_status(:success)
        expect_job_enqueued
        expect(Rails.logger).not_to have_received(:warn).with(/nenhum app secret configurado/)
      end

      it 'returns unauthorized when signature is missing' do
        post_instagram_webhook(body)

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
        expect(Rails.logger).to have_received(:warn).with(/rejeitada.*ausente/).once
      end

      it 'returns unauthorized when signature is invalid' do
        post_instagram_webhook(body, headers: { signature_header => 'sha256=invalid-signature' })

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
        expect(Rails.logger).to have_received(:warn).with(/rejeitada.*invalida/).once
      end

      it 'returns unauthorized when the signature has no sha256= prefix' do
        digest = OpenSSL::HMAC.hexdigest('SHA256', instagram_secret, body)

        post_instagram_webhook(body, headers: { signature_header => digest })

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
      end

      it 'returns unauthorized when the body was changed after signing' do
        signed_headers = { signature_header => signature_for(body, instagram_secret) }

        post_instagram_webhook(dm_params.merge(object: 'instagram', tampered: true).to_json, headers: signed_headers)

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
      end

      it 'returns unauthorized when the request is signed with a different secret' do
        post_instagram_webhook(body, secret: 'segredo-de-outro-app')

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
      end

      it 'does not log the "no secret" warning when it rejects the request' do
        post_instagram_webhook(body)

        expect(Rails.logger).not_to have_received(:warn).with(/nenhum app secret configurado/)
      end
    end

    context 'when only FB_APP_SECRET is configured' do
      around do |example|
        with_modified_env(FB_APP_SECRET: facebook_secret) { example.run }
      end

      it 'accepts webhook payloads signed with the Facebook app secret' do
        post_instagram_webhook(body, secret: facebook_secret)

        expect(response).to have_http_status(:success)
        expect_job_enqueued
      end

      it 'returns unauthorized when signature is missing' do
        post_instagram_webhook(body)

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
      end
    end

    context 'when both INSTAGRAM_APP_SECRET and FB_APP_SECRET are configured' do
      around do |example|
        with_modified_env(INSTAGRAM_APP_SECRET: instagram_secret, FB_APP_SECRET: facebook_secret) { example.run }
      end

      it 'accepts a request signed with either one of them' do
        post_instagram_webhook(body, secret: instagram_secret)
        expect(response).to have_http_status(:success)

        post_instagram_webhook(body, secret: facebook_secret)
        expect(response).to have_http_status(:success)

        expect(Webhooks::InstagramEventsJob).to have_received(:perform_later).twice
      end
    end

    context 'when the global secret comes from the installation config' do
      it 'uses the value saved in InstallationConfig (Super Admin)' do
        InstallationConfig.create!(name: 'INSTAGRAM_APP_SECRET', value: instagram_secret, locked: false)
        GlobalConfig.clear_cache

        post_instagram_webhook(body)
        expect(response).to have_http_status(:unauthorized)

        post_instagram_webhook(body, secret: instagram_secret)
        expect(response).to have_http_status(:success)
      end

      it 'falls back to the ENV variable when the installation config row exists but is blank' do
        # ConfigLoader semeia as linhas *_APP_SECRET sem valor; o ENV do Railway precisa continuar valendo.
        InstallationConfig.create!(name: 'INSTAGRAM_APP_SECRET', value: nil, locked: false)
        InstallationConfig.create!(name: 'FB_APP_SECRET', value: nil, locked: false)
        GlobalConfig.clear_cache

        with_modified_env INSTAGRAM_APP_SECRET: instagram_secret do
          post_instagram_webhook(body)
          expect(response).to have_http_status(:unauthorized)

          post_instagram_webhook(body, secret: instagram_secret)
          expect(response).to have_http_status(:success)
        end
      end

      it 'reads the ENV secrets without side effects when the installation config rows are blank' do
        rows = %w[INSTAGRAM_APP_SECRET FB_APP_SECRET].map { |name| InstallationConfig.create!(name: name, value: nil, locked: false) }
        GlobalConfig.clear_cache
        updated_ats = rows.map { |row| row.reload.updated_at }
        allow(GlobalConfig).to receive(:clear_cache).and_call_original

        with_modified_env INSTAGRAM_APP_SECRET: instagram_secret, FB_APP_SECRET: facebook_secret do
          3.times { post_instagram_webhook(body, secret: facebook_secret) }
        end

        expect(response).to have_http_status(:success)
        expect(Webhooks::InstagramEventsJob).to have_received(:perform_later).exactly(3).times
        expect(GlobalConfig).not_to have_received(:clear_cache)
        expect(InstallationConfig.where(name: %w[INSTAGRAM_APP_SECRET FB_APP_SECRET]).count).to eq(2)
        expect(rows.map { |row| row.reload.value }).to all(be_nil)
        expect(rows.map { |row| row.reload.updated_at }).to eq(updated_ats)
      end

      it 'reads the ENV secrets without creating installation config rows or clearing the cache when there are none' do
        allow(GlobalConfig).to receive(:clear_cache).and_call_original

        with_modified_env INSTAGRAM_APP_SECRET: instagram_secret do
          3.times { post_instagram_webhook(body, secret: instagram_secret) }
        end

        expect(response).to have_http_status(:success)
        expect(GlobalConfig).not_to have_received(:clear_cache)
        expect(InstallationConfig.where(name: %w[INSTAGRAM_APP_SECRET FB_APP_SECRET])).to be_empty
      end

      it 'keeps the Super Admin value ahead of the ENV one' do
        InstallationConfig.create!(name: 'INSTAGRAM_APP_SECRET', value: instagram_secret, locked: false)
        GlobalConfig.clear_cache

        with_modified_env INSTAGRAM_APP_SECRET: 'valor-do-env' do
          post_instagram_webhook(body, secret: 'valor-do-env')
          expect(response).to have_http_status(:unauthorized)

          post_instagram_webhook(body, secret: instagram_secret)
          expect(response).to have_http_status(:success)
        end
      end
    end

    context 'when checking the signature before doing any work' do
      let(:many_messaging_items) do
        Array.new(50) do |index|
          { sender: { id: "sender-#{index}" }, recipient: { id: "recipient-#{index}" }, message: { mid: "mid-#{index}", text: 'oi' } }
        end
      end
      let(:big_body) { { object: 'instagram', entry: [{ id: 'entry-1', messaging: many_messaging_items }] }.to_json }

      it 'does not query channels for an unsigned request, however many items the payload carries' do
        expect(Channel::Instagram).not_to receive(:find_by)
        expect(Channel::FacebookPage).not_to receive(:find_by)

        with_modified_env INSTAGRAM_APP_SECRET: instagram_secret do
          post_instagram_webhook(big_body)
        end

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
      end

      it 'does not query channels for a signed request either, since secrets are global only' do
        expect(Channel::Instagram).not_to receive(:find_by)
        expect(Channel::FacebookPage).not_to receive(:find_by)

        with_modified_env INSTAGRAM_APP_SECRET: instagram_secret do
          post_instagram_webhook(big_body, secret: instagram_secret)
        end

        expect(response).to have_http_status(:success)
        expect_job_enqueued
      end

      it 'does not run any channel query while rejecting a request with a bogus signature' do
        queries = []
        callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?('instagram_id') }

        ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
          with_modified_env INSTAGRAM_APP_SECRET: instagram_secret do
            post_instagram_webhook(big_body, headers: { signature_header => 'sha256=invalid-signature' })
          end
        end

        expect(response).to have_http_status(:unauthorized)
        expect(queries).to be_empty
      end
    end

    context 'when META_WEBHOOK_REQUIRE_SIGNATURE is on and no secret is configured' do
      around do |example|
        with_modified_env(META_WEBHOOK_REQUIRE_SIGNATURE: 'true') { example.run }
      end

      it 'returns unauthorized for an unsigned request and does not enqueue' do
        post_instagram_webhook(body)

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
        expect(Rails.logger).to have_received(:warn).with(/rejeitada.*nenhum app secret configurado.*META_WEBHOOK_REQUIRE_SIGNATURE/).once
      end

      it 'returns unauthorized even when the request carries a signature' do
        post_instagram_webhook(body, secret: 'qualquer-segredo')

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
      end

      it 'accepts a valid signature once a secret is configured' do
        with_modified_env INSTAGRAM_APP_SECRET: instagram_secret do
          post_instagram_webhook(body, secret: instagram_secret)
        end

        expect(response).to have_http_status(:success)
        expect_job_enqueued
      end
    end

    context 'when META_WEBHOOK_REQUIRE_SIGNATURE is off or has an unknown value' do
      ['false', '0', 'no', '', 'talvez'].each do |value|
        it "keeps accepting requests without a secret when the flag is #{value.inspect}" do
          with_modified_env META_WEBHOOK_REQUIRE_SIGNATURE: value do
            post_instagram_webhook(body)
          end

          expect(response).to have_http_status(:success)
          expect_job_enqueued
        end
      end
    end

    context 'when looking at the payload that reaches the job' do
      it 'enqueues only the entry array of the body, with indifferent access, ignoring the query string' do
        enqueued = nil
        allow(Webhooks::InstagramEventsJob).to receive(:perform_later) { |args| enqueued = args }

        with_modified_env INSTAGRAM_APP_SECRET: instagram_secret do
          post '/webhooks/instagram?injected=1&entry=bogus',
               params: body,
               headers: { 'CONTENT_TYPE' => 'application/json', signature_header => signature_for(body, instagram_secret) }
        end

        expect(response).to have_http_status(:success)
        expect(enqueued).to be_an(Array)
        expect(enqueued.first).to be_a(ActiveSupport::HashWithIndifferentAccess)
        expect(enqueued.first[:messaging].first[:recipient][:id]).to eq('chatwoot-app-user-id-1')
      end

      it 'survives the ActiveJob serialization keeping indifferent access' do
        enqueued = nil
        allow(Webhooks::InstagramEventsJob).to receive(:perform_later) { |args| enqueued = args }

        post_instagram_webhook(body)

        round_trip = ActiveJob::Arguments.deserialize(ActiveJob::Arguments.serialize([enqueued])).first
        expect(round_trip.first[:messaging].first[:message][:text]).to eq('This is the first message from the customer')
      end
    end

    context 'when the payload is malformed' do
      let(:malformed_bodies) do
        {
          'no object' => { entry: [] },
          'object as an array' => { object: ['instagram'], entry: [] },
          'entry as an object' => { object: 'instagram', entry: { messaging: [] } },
          'entry as a string' => { object: 'instagram', entry: 'texto' },
          'messaging as a string' => { object: 'instagram', entry: [{ messaging: 'texto' }] },
          'messaging items as numbers' => { object: 'instagram', entry: [{ messaging: [1, 2] }] },
          'message as a string' => { object: 'instagram', entry: [{ messaging: [{ message: 'texto' }] }] }
        }
      end

      it 'answers 401 instead of 500 when a secret is configured and the request is unsigned' do
        with_modified_env INSTAGRAM_APP_SECRET: instagram_secret do
          malformed_bodies.each do |label, malformed|
            post_instagram_webhook(malformed.to_json)

            expect(response.status).to eq(401), "expected 401 for #{label}, got #{response.status}"
          end
        end
        expect_job_not_enqueued
      end

      it 'does not answer 5xx when no secret is configured' do
        malformed_bodies.each do |label, malformed|
          post_instagram_webhook(malformed.to_json)

          expect(response.status).to be < 500, "expected no 5xx for #{label}, got #{response.status}"
        end
      end

      it 'does not answer 5xx when the request is properly signed' do
        with_modified_env INSTAGRAM_APP_SECRET: instagram_secret do
          malformed_bodies.each do |label, malformed|
            post_instagram_webhook(malformed.to_json, secret: instagram_secret)

            expect(response.status).to be < 500, "expected no 5xx for #{label}, got #{response.status}"
          end
        end
      end

      it 'does not enqueue anything for payloads that are not an instagram entry list' do
        with_modified_env INSTAGRAM_APP_SECRET: instagram_secret do
          malformed_bodies.except('messaging as a string', 'messaging items as numbers', 'message as a string').each_value do |malformed|
            post_instagram_webhook(malformed.to_json, secret: instagram_secret)
          end
        end

        expect_job_not_enqueued
      end

      it 'answers 400 for a JSON body that is not an object, once the signature is valid' do
        with_modified_env INSTAGRAM_APP_SECRET: instagram_secret do
          post_instagram_webhook([1, 2].to_json, secret: instagram_secret)
        end

        expect(response).to have_http_status(:bad_request)
        expect_job_not_enqueued
      end
    end

    context 'when a secret has surrounding whitespace' do
      it 'strips the global secret before comparing' do
        with_modified_env INSTAGRAM_APP_SECRET: " #{instagram_secret}\n" do
          post_instagram_webhook(body, secret: instagram_secret)
        end

        expect(response).to have_http_status(:success)
        expect_job_enqueued
      end
    end

    context 'when processing echo events' do
      let!(:echo_params) { build(:instagram_story_mention_event_with_echo).with_indifferent_access }
      let(:echo_body) { echo_params.merge(object: 'instagram').to_json }

      it 'delays processing for echo events by 2 seconds' do
        job_double = class_double(Webhooks::InstagramEventsJob)
        allow(Webhooks::InstagramEventsJob).to receive(:set).with(wait: 2.seconds).and_return(job_double)
        allow(job_double).to receive(:perform_later)

        with_modified_env INSTAGRAM_APP_SECRET: instagram_secret do
          post_instagram_webhook(echo_body, secret: instagram_secret)
        end

        expect(response).to have_http_status(:success)
        expect(Webhooks::InstagramEventsJob).to have_received(:set).with(wait: 2.seconds)
        expect(job_double).to have_received(:perform_later)
      end
    end
  end
end
