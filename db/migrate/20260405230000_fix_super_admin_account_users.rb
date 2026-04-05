class FixSuperAdminAccountUsers < ActiveRecord::Migration[7.0]
  def up
    # The ensure_super_admin_accounts initializer created AccountUser records
    # that may be missing required fields, causing 500 errors on /api/v1/profile.
    # Remove auto-created records and re-create them properly.
    super_admin_ids = User.where(type: 'SuperAdmin').pluck(:id)
    return if super_admin_ids.empty?

    super_admin_ids.each do |user_id|
      Account.pluck(:id).each do |account_id|
        # Skip if already a valid member
        existing = AccountUser.find_by(user_id: user_id, account_id: account_id)
        next if existing&.valid?

        # Delete invalid record if it exists
        existing&.destroy

        # Re-create properly
        AccountUser.create!(
          user_id: user_id,
          account_id: account_id,
          role: :administrator
        )
      rescue StandardError => e
        Rails.logger.warn "fix_super_admin_account_users: #{e.message} (user=#{user_id}, account=#{account_id})"
      end
    end
  end

  def down
    # no-op
  end
end
