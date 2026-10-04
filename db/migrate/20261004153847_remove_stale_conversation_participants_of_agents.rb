# Adalink: backfill de dados, idempotente e conservador.
#
# O Chatwoot faz de todo responsável um participante da conversa (ParticipationListener) e
# nunca o remove. Até aqui a limpeza só existia para WhatsApp e só daqui para frente. Agora
# que o participante enxerga a conversa nas visões restritas ("Minhas" e "Não atribuídas"),
# as linhas antigas de ex-responsáveis virariam acesso na lista assim que uma conta configurar
# papéis (hoje quase ninguém tem custom_role; os grupos do CRM criam os papéis depois).
#
# Por isso o critério NÃO depende do papel de hoje: apaga de conversation_participants as linhas
# cujo usuário é AGENTE na conta da conversa (account_users.role = 0, com ou sem custom_role) e
# NÃO é o responsável atual da conversa. Mantém as de administrador (role = 1) e as do responsável
# atual. Participantes sem AccountUser na conta da conversa ficam como estão. O CRM não usa
# participantes para nada; o efeito é o agente deixar de receber avisos de "participante" nessas
# conversas.
#
# Conta as linhas por conta no log e registra o que foi removido (id, conversa, usuário) para
# permitir recriar uma participação se alguém reclamar. Rodar de novo não remove mais nada.
# Não é reversível (down não faz nada): quem quiser restaurar usa o log.
class RemoveStaleConversationParticipantsOfAgents < ActiveRecord::Migration[7.1]
  LOG_TAG = '[RemoveStaleConversationParticipantsOfAgents]'.freeze
  BATCH_SIZE = 1000

  # A mesma consulta, só de leitura, está na descrição do PR para contar antes de rodar em produção.
  CANDIDATES_SQL = <<~SQL.squish.freeze
    SELECT cp.id, cp.conversation_id, cp.user_id, c.account_id
    FROM conversation_participants cp
    JOIN conversations c ON c.id = cp.conversation_id
    JOIN account_users au ON au.account_id = c.account_id AND au.user_id = cp.user_id AND au.role = 0
    WHERE cp.user_id IS DISTINCT FROM c.assignee_id
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
      log("account #{account_id}: removed #{account_rows.size} stale participant row(s) of agents who are not the assignee")
      removed = account_rows.map { |row| row.values_at('id', 'conversation_id', 'user_id') }
      log("account #{account_id}: removed rows [id, conversation_id, user_id] #{removed.to_json}")
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
