# frozen_string_literal: true
#
# TEMPORÁRIO — initializer de diagnóstico.
#
# Captura exception em Captain::BaseTaskService#make_api_call e loga
# classe + mensagem + backtrace cru (não filtrado pelo Rails.backtrace_cleaner).
# Re-raise pra preservar o comportamento original — nada muda funcionalmente.
#
# Removido após root cause identificado.

module CaptainExceptionLogger
  def make_api_call(**kwargs)
    super
  rescue Exception => e # rubocop:disable Lint/RescueException
    feature = begin
      event_name
    rescue StandardError
      'unknown'
    end
    Rails.logger.error("[CaptainDebug] #{feature} FAILED: #{e.class}: #{e.message}")
    Rails.logger.error('[CaptainDebug] Backtrace (raw, unfiltered):')
    (e.backtrace || []).first(40).each do |line|
      Rails.logger.error("[CaptainDebug]   #{line}")
    end
    raise
  end
end

Rails.application.config.to_prepare do
  unless Captain::BaseTaskService.include?(CaptainExceptionLogger)
    Captain::BaseTaskService.prepend(CaptainExceptionLogger)
    Rails.logger.info('[CaptainDebug] Exception logger ATIVO (temporário)')
  end
end
