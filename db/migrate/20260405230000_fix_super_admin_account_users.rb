class FixSuperAdminAccountUsers < ActiveRecord::Migration[7.0]
  def up
    # Remove ALL AccountUser records that were auto-created by the broken initializer.
    # Keep only the original account 2 membership for SuperAdmin user.
    execute <<-SQL
      DELETE FROM account_users
      WHERE user_id IN (SELECT id FROM users WHERE type = 'SuperAdmin')
      AND account_id != 2
    SQL
  end

  def down
    # no-op
  end
end
