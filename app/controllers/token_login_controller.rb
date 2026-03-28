# Auto-login via API access token for iframe embedding
# GET /sso/login?token=xxx
# Validates the API token, generates a short-lived SSO token,
# and redirects to the login page which auto-authenticates.
class TokenLoginController < ActionController::Base
  def create
    access_token = AccessToken.find_by(token: params[:token])

    if access_token&.owner.is_a?(User)
      user = access_token.owner
      sso_token = user.generate_sso_auth_token
      redirect_to "/app/login?email=#{CGI.escape(user.email)}&sso_auth_token=#{sso_token}", allow_other_host: false
    else
      # Debug: show what happened instead of silent redirect
      render plain: "Token not found or owner is not a User. Token received: #{params[:token].present? ? 'yes' : 'no'}", status: :unauthorized
    end
  end
end
