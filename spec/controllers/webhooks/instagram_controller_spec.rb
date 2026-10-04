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

    context 'when no app secret is configured anywhere (channel or global)' do
      it 'accepts an unsigned request, enqueues the job and logs a warning once' do
        post_instagram_webhook(body)

        expect(response).to have_http_status(:success)
        expect_job_enqueued
        expect(Rails.logger).to have_received(:warn).with(/nenhum app secret configurado/).once
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
    end

    context 'when the channel has its own app secret' do
      let(:channel_secret) { 'channel-instagram-secret' }
      let(:instagram_channel) { create(:channel_instagram, instagram_id: 'chatwoot-app-user-id-1') }

      before do
        # Channel::Instagram não tem coluna app_secret hoje; o concern aceita o segredo se o canal expuser um.
        instagram_channel.define_singleton_method(:app_secret) { 'channel-instagram-secret' }
        allow(Channel::Instagram).to receive(:find_by).and_call_original
        allow(Channel::Instagram).to receive(:find_by).with(instagram_id: 'chatwoot-app-user-id-1').and_return(instagram_channel)
      end

      it 'accepts a request signed with the channel secret when no global secret exists' do
        post_instagram_webhook(body, secret: channel_secret)

        expect(response).to have_http_status(:success)
        expect_job_enqueued
        expect(Rails.logger).not_to have_received(:warn).with(/nenhum app secret configurado/)
      end

      it 'returns unauthorized when the request is unsigned and no global secret exists' do
        post_instagram_webhook(body)

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
      end

      it 'gives the channel secret priority over the global secret' do
        with_modified_env INSTAGRAM_APP_SECRET: instagram_secret do
          post_instagram_webhook(body, secret: channel_secret)
        end

        expect(response).to have_http_status(:success)
        expect_job_enqueued
      end

      it 'does not accept the global secret for a channel that has its own secret' do
        with_modified_env INSTAGRAM_APP_SECRET: instagram_secret do
          post_instagram_webhook(body, secret: instagram_secret)
        end

        expect(response).to have_http_status(:unauthorized)
        expect_job_not_enqueued
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
