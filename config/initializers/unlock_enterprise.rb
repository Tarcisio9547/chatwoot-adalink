Rails.application.config.after_initialize do
  Rails.application.config.to_prepare do
    # no-op
  end

  ActiveSupport.on_load(:active_record) do
    begin
      next unless ActiveRecord::Base.connection.table_exists?('installation_configs')

      InstallationConfig.find_or_create_by(name: 'INSTALLATION_PRICING_PLAN').update_column(:value, 'Enterprise')
      InstallationConfig.find_or_create_by(name: 'INSTALLATION_PRICING_PLAN_QUANTITY').update_column(:value, '999')

      next unless ActiveRecord::Base.connection.table_exists?('accounts')

      [2, 3].each do |account_id|
        account = Account.find_by(id: account_id)
        next unless account
        attrs = account.custom_attributes || {}
        account.update_column(:custom_attributes, attrs.merge('plan_name' => 'Enterprise'))
      end
    rescue StandardError => e
      Rails.logger.warn "[unlock_enterprise] #{e.message}"
    end
  end
end
