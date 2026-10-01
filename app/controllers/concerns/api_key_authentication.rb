# Bearer-key authentication for machine clients (docs/AGENT_API.md).
#
#   class Api::V1::BaseController < ActionController::API
#     include ApiKeyAuthentication
#   end
#
# One include gives a controller: `Authorization: Bearer <key>` resolved to
# `current_user` / `current_api_key`, the JSON error envelope
# `{ "error": { "code": ..., "message": ... } }`, and an ErrorLog row for
# anything unexpected. It is a concern, not a base class, so a surface that
# cannot inherit from Api::V1::BaseController (an MCP endpoint, say) gets the
# identical authentication and the identical errors.
#
# WHAT IT DELIBERATELY DOES NOT DO, and why each is safe to drop for a key:
#
#   * No cookie session, so no CSRF token and no OPSEC-045 session-token check.
#     Both defend a browser's ambient credential; a bearer key is sent on
#     purpose, per request, and is revoked by revoking the key.
#   * No `allow_browser`. That guard 406s any non-browser user agent, which is
#     every client this surface exists for.
#   * No profile-completion redirect. A redirect to an HTML form is not an
#     answer an agent can act on.
#   * No IP geo gate. The request comes from the agent's servers, not the
#     player. Eligibility was checked in the player's own browser when the key
#     was minted and is carried by the key (ApiKey#eligibility).
#
# WHAT IT KEEPS: the account freeze (OPSEC-048). A frozen account is frozen for
# every credential that can reach it — `require_unfrozen_account` is here for
# every action that moves money, exactly as on the web.
#
# Include it in an ActionController::API controller. In a controller that also
# has cookie sessions, the host must turn CSRF off for these actions itself.
module ApiKeyAuthentication
  extend ActiveSupport::Concern

  BEARER_PATTERN = /\ABearer\s+(\S+)\s*\z/i
  WWW_AUTHENTICATE = 'Bearer realm="Turf Monster API"'.freeze

  AUTH_ERRORS = {
    missing_api_key: "Send your API key in the Authorization header: Bearer <key>.",
    invalid_api_key: "That API key is not recognised.",
    revoked_api_key: "That API key has been revoked. Create a new one on your account page.",
    expired_api_key: "That API key has expired. Create a new one on your account page."
  }.freeze

  FROZEN_MESSAGE = "This account is on hold pending review of a recent payment. " \
                   "Contact support@turfmonster.media.".freeze

  included do
    # ORDER IS LOAD-BEARING: Rescuable resolves handlers last-registered-first,
    # so the catch-all goes FIRST and the specific handlers after it.
    rescue_from StandardError, with: :render_api_unexpected_error
    rescue_from ActiveRecord::RecordNotFound, with: :render_api_not_found
    rescue_from ActionController::ParameterMissing, with: :render_api_bad_request

    before_action :authenticate_api_key!
  end

  private

  attr_reader :current_api_key

  def current_user
    current_api_key&.user
  end

  def authenticate_api_key!
    raw = bearer_token
    return render_api_auth_error(:missing_api_key) if raw.blank?

    key = ApiKey.find_by_raw_token(raw)
    return render_api_auth_error(:invalid_api_key) if key.nil?
    return render_api_auth_error(:revoked_api_key) if key.revoked?
    return render_api_auth_error(:expired_api_key) if key.expired?

    @current_api_key = key
    Current.user = key.user
    key.touch_last_used!
  end

  def bearer_token
    request.authorization.to_s[BEARER_PATTERN, 1]
  end

  # OPSEC-048, the API's copy. Hang it on every action that moves money or
  # spends a free entry; read-only actions stay open, as they do on the web.
  def require_unfrozen_account
    return unless current_user&.frozen?

    render_api_error(:account_frozen, FROZEN_MESSAGE, status: :forbidden)
  end

  def render_api_error(code, message, status:)
    render json: { error: { code: code.to_s, message: message } }, status: status
  end

  def render_api_auth_error(code)
    response.set_header("WWW-Authenticate", WWW_AUTHENTICATE)
    render_api_error(code, AUTH_ERRORS.fetch(code), status: :unauthorized)
  end

  def render_api_not_found(_exception = nil)
    render_api_error(:not_found, "No such resource.", status: :not_found)
  end

  def render_api_bad_request(exception)
    render_api_error(:bad_request, exception.message, status: :bad_request)
  end

  # Anything unplanned: write the ErrorLog row an operator will look for, then
  # answer in the envelope. The exception's own message is NOT sent — it can
  # carry internals, and a client cannot act on it.
  def render_api_unexpected_error(exception)
    log_api_error(exception)
    raise exception if reraise_unexpected_api_errors?

    render_api_error(:internal_error, "Something went wrong on our side. Try again shortly.",
                     status: :internal_server_error)
  end

  # Development and test want the backtrace, not a tidy 500.
  def reraise_unexpected_api_errors?
    Rails.env.local?
  end

  # A logger that can veto the response it is describing is worse than none.
  def log_api_error(exception)
    error_log = ErrorLog.capture!(exception)
    if (user = current_user)
      error_log.target = user
      error_log.target_name = user.slug if user.respond_to?(:slug)
      error_log.save!
    end
  rescue StandardError => e
    Rails.logger.error("[api] error log failed: #{e.class}: #{e.message}")
  end
end
