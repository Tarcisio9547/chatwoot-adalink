class ConfirmAllAgents < ActiveRecord::Migration[7.0]
  def up
    # Auto-confirm all unconfirmed users created via CRM sync.
    # Self-hosted: email confirmation is unnecessary since users are
    # created by admins, not self-registered.
    User.where(confirmed_at: nil).update_all(confirmed_at: Time.current)
  end

  def down
    # no-op
  end
end
