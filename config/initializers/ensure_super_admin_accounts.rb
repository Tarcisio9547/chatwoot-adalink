# Ensure all SuperAdmin users have administrator access to every account.
# This runs once on server startup — safe for self-hosted multi-tenant.
Rails.application.config.after_initialize do
  User.where(type: 'SuperAdmin').find_each do |user|
    Account.find_each do |account|
      AccountUser.find_or_create_by(account: account, user: user) do |au|
        au.role = :administrator
      end
    end
  end
rescue StandardError => e
  Rails.logger.warn "ensure_super_admin_accounts: #{e.message}"
end
