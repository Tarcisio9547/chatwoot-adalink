# config/initializers/allow_iframe.rb
# This allows the application to be embedded in an iframe (like the CRM)
# by removing the default X-Frame-Options header added by Rails.
Rails.application.config.action_dispatch.default_headers.delete('X-Frame-Options')
