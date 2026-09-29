class SetDefaultLocalePtBr < ActiveRecord::Migration[7.0]
  def up
    # Set all existing accounts to Portuguese (Brazil)
    Account.update_all(locale: 'pt_BR') if Account.column_names.include?('locale') # rubocop:disable Rails/SkipsModelValidations

    # Set all existing users to Portuguese
    return unless User.column_names.include?('ui_settings')

    User.find_each do |user|
      settings = user.ui_settings || {}
      settings['locale'] = 'pt_BR'
      user.update_column(:ui_settings, settings) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def down
    Account.update_all(locale: 'en') if Account.column_names.include?('locale') # rubocop:disable Rails/SkipsModelValidations
  end
end
