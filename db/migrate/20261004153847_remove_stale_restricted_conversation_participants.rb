# Adalink: backfill de dados, idempotente e conservador.
#
# O Chatwoot faz de todo responsável um participante da conversa (ParticipationListener) e
# nunca o remove. Até aqui a limpeza só existia para WhatsApp e só daqui para frente. Agora
# que o participante enxerga a conversa nas visões restritas ("Minhas" e "Não atribuídas"),
# as linhas antigas de ex-responsáveis virariam acesso na lista no deploy.
#
# Apaga de conversation_participants as linhas cujo usuário tem papel RESTRITO na conta da
# conversa (custom_role sem conversation_manage, em AccountUser de agente) e NÃO é o
# responsável atual da conversa. Não toca nas linhas de administrador, de agente sem
# custom_role, de custom_role com conversation_manage ("Todas") nem do responsável atual.
#
# Conta as linhas por conta no log e registra o que foi removido (id, conversa, usuário) para
# permitir recriar uma participação se alguém reclamar. Rodar de novo não remove mais nada.
# Não é reversível (down não faz nada): quem quiser restaurar usa o log.
class RemoveStaleRestrictedConversationParticipants < ActiveRecord::Migration[7.1]
  LOG_TAG = '[RemoveStaleRestrictedConversationParticipants]'.freeze
  BATCH_SIZE = 1000

  # A mesma consulta, só de leitura, está na descrição do PR para contar antes de rodar em produção.
  CANDIDATES_SQL = <<~SQL.squish.freeze
    SELECT cp.id, cp.conversation_id, cp.user_id, c.account_id
    FROM conversation_participants cp
    JOIN conversations c ON c.id = cp.conversation_id
    JOIN account_users au ON au.account_id = c.account_id AND au.user_id = cp.user_id AND au.role = 0
    JOIN custom_roles cr ON cr.id = au.custom_role_id
    WHERE NOT ('conversation_manage' = ANY (COALESCE(cr.permissions, '{}')))
      AND cp.user_id IS DISTINCT FROM c.assignee_id
    ORDER BY c.account_id, cp.id
  SQL

  def up
    rows = select_all(CANDIDATES_SQL).to_a
    total = 0

    rows.group_by { |row| row['account_id'] }.each do |account_id, account_rows|
      account_rows.each_slice(BATCH_SIZE) do |batch|
        execute("DELETE FROM conversation_participants WHERE id IN (#{batch.pluck('id').map(&:to_i).join(',')})")
      end
      total += account_rows.size
      log("account #{account_id}: removed #{account_rows.size} stale participant row(s) of restricted users")
      log("account #{account_id}: removed rows [id, conversation_id, user_id] #{account_rows.map { |row| row.values_at('id', 'conversation_id', 'user_id') }.to_json}")
    end

    log("total removed: #{total}")
  end

  def down
    # Limpeza de dados: não há como saber quais linhas existiam. O log do up traz [id, conversa, usuário].
  end

  private

  def log(message)
    say(message, true)
    Rails.logger.info("#{LOG_TAG} #{message}")
  end
end
