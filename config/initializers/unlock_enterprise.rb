Rails.application.config.after_initialize do
  next unless defined?(InstallationConfig)

  InstallationConfig.find_or_create_by(name: 'INSTALLATION_PRICING_PLAN').update(value: 'Enterprise')
  InstallationConfig.find_or_create_by(name: 'INSTALLATION_PRICING_PLAN_QUANTITY').update(value: '999')

  [2, 3].each do |account_id|
    account = Account.find_by(id: account_id)
    next unless account

    account.custom_attributes ||= {}
    account.custom_attributes['plan_name'] = 'Enterprise'
    account.save!
  end
rescue StandardError => e
  Rails.logger.warn "[unlock_enterprise] #{e.message}"
end
