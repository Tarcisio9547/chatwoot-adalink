class Webhooks::InstagramController < ActionController::API
  include MetaTokenVerifyConcern

  before_action :verify_meta_signature!, only: :events

  def events
    Rails.logger.info('Instagram webhook received events')
    return head :bad_request if meta_webhook_payload.nil?

    unless meta_webhook_payload['object'].to_s.casecmp('instagram').zero?
      Rails.logger.warn("Message is not received from the instagram webhook event: #{meta_webhook_payload['object'].inspect.truncate(80)}")
      return head :unprocessable_entity
    end

    # Só o corpo assinado chega ao job (query string e parâmetros do Rails ficam de fora).
    entry_params = meta_webhook_payload['entry']
    return head :bad_request unless entry_params.is_a?(Array) && entry_params.all?(Hash)

    enqueue_events(entry_params)
    render json: :ok
  end

  private

  def enqueue_events(entry_params)
    if contains_echo_event?(entry_params)
      # Add delay to prevent race condition where echo arrives before send message API completes
      # This avoids duplicate messages when echo comes early during API processing
      ::Webhooks::InstagramEventsJob.set(wait: 2.seconds).perform_later(entry_params)
    else
      ::Webhooks::InstagramEventsJob.perform_later(entry_params)
    end
  end

  def contains_echo_event?(entry_params)
    entry_params.any? do |entry|
      # Check messaging array for echo events
      messaging_events = entry[:messaging]
      messaging_events.is_a?(Array) && messaging_events.any? { |messaging| meta_payload_dig(messaging, :message, :is_echo).present? }
    end
  end

  def valid_token?(token)
    # Validates against both IG_VERIFY_TOKEN (Instagram channel via Facebook page) and
    # INSTAGRAM_VERIFY_TOKEN (Instagram channel via direct Instagram login)
    token == GlobalConfigService.load('IG_VERIFY_TOKEN', '') ||
      token == GlobalConfigService.load('INSTAGRAM_VERIFY_TOKEN', '')
  end

  # Só segredos globais: aceita qualquer um entre INSTAGRAM_APP_SECRET (login direto do Instagram) e
  # FB_APP_SECRET (Instagram via página do Facebook). Nenhuma consulta ao banco por item do payload antes de
  # a assinatura ser conferida: as tabelas dos canais Instagram nem guardam segredo.
  def meta_app_secrets
    meta_global_secret_config_names.filter_map { |config_name| global_meta_app_secret(config_name) }
  end

  def meta_global_secret_config_names
    %w[INSTAGRAM_APP_SECRET FB_APP_SECRET]
  end
end
