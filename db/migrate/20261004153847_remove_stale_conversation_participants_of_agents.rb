# Adalink: backfill de dados, idempotente e conservador.
#
# O Chatwoot faz de todo responsável um participante da conversa (ParticipationListener) e
# nunca o remove. Até aqui a limpeza só existia para WhatsApp e só daqui para frente. Agora
# que o participante enxerga a conversa nas visões restritas ("Minhas" e "Não atribuídas"),
# as linhas antigas de ex-responsáveis virariam acesso na lista assim que uma conta configurar
# papéis (hoje quase ninguém tem custom_role; os grupos do CRM criam os papéis depois).
#
# Por isso o critério NÃO depende do papel de hoje: apaga de conversation_participants as linhas
# cujo usuário é AGENTE na conta da conversa (account_users.role = 0, com ou sem custom_role),
# NÃO é o responsável atual da conversa E é membro da caixa da conversa (inbox_members). Ficam:
# administrador (role = 1), responsável atual e quem NÃO é membro da caixa.
#
# Quem não é membro da caixa é o gestor que o CRM adiciona como participante de uma conversa do
# WhatsApp Pessoal (caixa Channel::Api, wa-pessoal-mark-work e wa-classifier-confirm): o acesso
# dele vem SÓ da participação e não pode sair aqui. O ex-responsável quase sempre é membro da
# caixa. Participantes sem AccountUser na conta da conversa também ficam como estão.
#
# Antes do DELETE, copia as linhas para conversation_participants_backup_20261004 (mesmas colunas
# mais removed_at), na mesma transação da migration; o down restaura a partir dela e não apaga a
# tabela de backup (é a evidência; apague à mão quando não precisar mais). Loga a contagem por
# conta e os ids removidos. Rodar de novo não remove mais nada. Lotes de 1000 ids por INSERT/DELETE.
class RemoveStaleConversationParticipantsOfAgents < ActiveRecord::Migration[7.1]
  LOG_TAG = '[RemoveStaleConversationParticipantsOfAgents]'.freeze
  BACKUP_TABLE = 'conversation_participants_backup_20261004'.freeze
  BATCH_SIZE = 1000

  # A mesma consulta, só de leitura, está na descrição do PR para contar antes de rodar em produção.
  CANDIDATES_SQL = <<~SQL.squish.freeze
    SELECT cp.id, cp.conversation_id, cp.user_id, c.account_id
    FROM conversation_participants cp
    JOIN conversations c ON c.id = cp.conversation_id
    JOIN account_users au ON au.account_id = c.account_id AND au.user_id = cp.user_id AND au.role = 0
    WHERE cp.user_id IS DISTINCT FROM c.assignee_id
      AND EXISTS (SELECT 1 FROM inbox_members im WHERE im.inbox_id = c.inbox_id AND im.user_id = cp.user_id)
    ORDER BY c.account_id, cp.id
  SQL

  COLUMNS = 'id, account_id, conversation_id, user_id, created_at, updated_at'.freeze

  def up
    rows = select_all(CANDIDATES_SQL).to_a
    create_backup_table
    total = 0

    rows.group_by { |row| row['account_id'] }.each do |account_id, account_rows|
      account_rows.each_slice(BATCH_SIZE) { |batch| back_up_and_delete(batch.pluck('id').map(&:to_i)) }
      total += account_rows.size
      log("account #{account_id}: removed #{account_rows.size} stale participant row(s) of agents who are not the assignee")
      removed = account_rows.map { |row| row.values_at('id', 'conversation_id', 'user_id') }
      log("account #{account_id}: removed rows [id, conversation_id, user_id] #{removed.to_json}")
    end

    log("total removed: #{total} (copied to #{BACKUP_TABLE})")
  end

  # Restaura as linhas do backup (com os ids originais), sem duplicar quem já voltou à mão.
  # Não apaga a tabela de backup.
  def down
    return unless table_exists?(BACKUP_TABLE)

    restored = execute(<<~SQL.squish).cmd_tuples
      INSERT INTO conversation_participants (#{COLUMNS})
      SELECT DISTINCT ON (conversation_id, user_id) #{COLUMNS}
      FROM #{BACKUP_TABLE}
      ORDER BY conversation_id, user_id, removed_at DESC
      ON CONFLICT DO NOTHING
    SQL
    log("restored #{restored} row(s) from #{BACKUP_TABLE} (the backup table was kept)")
  end

  private

  # Sem defaults, índices nem chaves (LIKE puro): só as colunas e os NOT NULL.
  def create_backup_table
    execute("CREATE TABLE IF NOT EXISTS #{BACKUP_TABLE} (LIKE conversation_participants)")
    execute("ALTER TABLE #{BACKUP_TABLE} ADD COLUMN IF NOT EXISTS removed_at timestamp(6) NOT NULL DEFAULT CURRENT_TIMESTAMP")
  end

  def back_up_and_delete(ids)
    list = ids.join(',')
    execute("INSERT INTO #{BACKUP_TABLE} (#{COLUMNS}) SELECT #{COLUMNS} FROM conversation_participants WHERE id IN (#{list})")
    execute("DELETE FROM conversation_participants WHERE id IN (#{list})")
  end

  def log(message)
    say(message, true)
    Rails.logger.info("#{LOG_TAG} #{message}")
  end
end
