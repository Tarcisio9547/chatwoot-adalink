# Auto-login via API access token for iframe embedding
# GET /sso/login?token=xxx
class TokenLoginController < ActionController::Base
  def create
    access_token = AccessToken.find_by(token: params[:token])

    if access_token&.owner.is_a?(User)
      user = access_token.owner
      sso_token = user.generate_sso_auth_token
      login_path = "/app/login?email=#{CGI.escape(user.email)}&sso_auth_token=#{sso_token}"
      # Force relative redirect — critical for same-origin proxy to work
      response.headers['Location'] = login_path
      head :found
    else
      response.headers['Location'] = '/app/login'
      head :found
    end
  end
end
