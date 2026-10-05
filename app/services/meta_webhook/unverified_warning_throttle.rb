# Controla o aviso "webhook Meta aceito sem conferir a assinatura" (quando não há app secret configurado):
# no máximo 1 aviso por hora por processo e por chave, para o log não virar ruído. Cada aviso informa
# quantas requisições foram aceitas sem conferência desde o aviso anterior.
class MetaWebhook::UnverifiedWarningThrottle
  INTERVAL_SECONDS = 3600

  @states = {}
  @mutex = Mutex.new

  class << self
    # Registra uma requisição aceita sem conferência.
    # Devolve [deve_avisar, requisicoes_aceitas_desde_o_ultimo_aviso (esta incluída)].
    def register(key, now = Time.current)
      @mutex.synchronize do
        state = (@states[key] ||= { last_warned_at: nil, accepted: 0 })
        state[:accepted] += 1
        next [false, state[:accepted]] unless warning_due?(state, now)

        accepted = state[:accepted]
        state[:last_warned_at] = now
        state[:accepted] = 0
        [true, accepted]
      end
    end

    # Usado pelos specs para começar cada exemplo sem o estado do anterior.
    def reset!
      @mutex.synchronize { @states.clear }
    end

    private

    def warning_due?(state, now)
      state[:last_warned_at].nil? || (now - state[:last_warned_at]) >= INTERVAL_SECONDS
    end
  end
end
