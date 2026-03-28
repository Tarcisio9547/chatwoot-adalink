class UpdateAdalinkBranding < ActiveRecord::Migration[7.0]
  def up
    # Force branding update — installation_config.yml defaults only apply on first seed
    configs = {
      'INSTALLATION_NAME' => 'Adalink Atendimento',
      'BRAND_NAME' => 'Adalink Atendimento',
      'BRAND_URL' => 'https://adalinkcrm.com',
      'WIDGET_BRAND_URL' => 'https://adalinkcrm.com',
      'DISPLAY_MANIFEST' => false
    }

    configs.each do |name, value|
      config = InstallationConfig.find_by(name: name)
      if config
        config.update!(value: value)
      end
    end
  end

  def down
    # Revert to Chatwoot defaults
    configs = {
      'INSTALLATION_NAME' => 'Chatwoot',
      'BRAND_NAME' => 'Chatwoot',
      'BRAND_URL' => 'https://www.chatwoot.com',
      'WIDGET_BRAND_URL' => 'https://www.chatwoot.com',
      'DISPLAY_MANIFEST' => true
    }

    configs.each do |name, value|
      config = InstallationConfig.find_by(name: name)
      config&.update!(value: value)
    end
  end
end
