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
# WHAT IT KEEPS, and how a write endpoint uses it:
#
#   * The account freeze (OPSEC-048), DEFAULT-DENY. A frozen account is refused
#     403 `account_frozen` on every request that is not a GET or a HEAD, with
#     nothing to remember: a new write endpoint is covered the day it is routed.
#     Reads stay open, as they do on the web. A controller opts an action out
#     by name — `allow_frozen_account_writes only: :call_tool` — and then owes
#     the check itself.
#   * The age gate, ON REQUEST. A key stamped `not_required` can outlive
#     ENABLE_AGE_GATE being turned on, so an action that enters a contest
#     re-asks: `before_action :require_age_verified`.
#
# Each gate is also a PLAIN QUESTION that renders nothing — `frozen_account_refusal`,
# `age_gate_refusal`, and `write_refusal` for both — returning nil or a Refusal
# (code, message, status). That is what a surface with ONE action and many
# operations calls (an MCP endpoint dispatching tools through one POST): a
# before_action cannot know which tool writes, and the answer has to go back in
# that surface's own envelope, not this one's.
#
#   refusal = write_refusal
#   return tool_error(refusal.code, refusal.message) if refusal
#
# Geo is NOT re-asked per request, on purpose (see above).
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
  AGE_GATE_MESSAGE = "Verify your age on turfmonster.media before entering a contest. " \
                     "Sign in, open your account page, and confirm your date of birth.".freeze

  NOT_FOUND_MESSAGE = "No such resource.".freeze

  # Why a request is being turned away, as data. `status` is a Rails status
  # symbol; a surface with its own envelope uses `code` and `message` only.
  Refusal = Struct.new(:code, :message, :status)

  included do
    # ORDER IS LOAD-BEARING: Rescuable resolves handlers last-registered-first,
    # so the catch-all goes FIRST and the specific handlers after it.
    rescue_from StandardError, with: :render_api_unexpected_error
    rescue_from ActiveRecord::RecordNotFound, with: :render_api_not_found
    rescue_from ActionController::ParameterMissing, with: :render_api_bad_request
    # A parameter of the wrong shape (Api::V1::StrictParams), and a body that
    # is not the JSON it claims to be.
    rescue_from ActionController::BadRequest, with: :render_api_bad_request
    rescue_from ActionDispatch::Http::Parameters::ParseError, with: :render_api_malformed_body

    before_action :authenticate_api_key!
    # After authentication, so a keyless write is still a 401, not a 403.
    before_action :refuse_frozen_account_writes
  end

  class_methods do
    # The explicit opt-out from the default freeze gate, for the actions named
    # in `only:`. An action named here is reachable by a frozen account on any
    # verb, so it owes `frozen_account_refusal` (or `require_unfrozen_account`)
    # wherever it actually writes.
    #
    # `only:` is REQUIRED and may not be empty. Called bare, skip_before_action
    # would lift the gate from every action of the controller, present and
    # future, which is the opposite of default-deny; so the one spelling that
    # does that does not load.
    def allow_frozen_account_writes(only:)
      actions = Array(only).map(&:to_sym)
      raise ArgumentError, "allow_frozen_account_writes needs only: with at least one action" if actions.empty?

      skip_before_action :refuse_frozen_account_writes, only: actions
    end
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

  # ── The write gates ────────────────────────────────────────────────────────
  # Three layers, each built on the one before:
  #   *_refusal        the question. Renders nothing; nil means "go ahead".
  #   require_*        the question as a before_action: renders the refusal.
  #   refuse_frozen_…  require_unfrozen_account on every non-read, by default.

  # OPSEC-048, the API's copy. nil, or why this account may not write.
  def frozen_account_refusal
    return unless current_user&.frozen?

    Refusal.new(:account_frozen, FROZEN_MESSAGE, :forbidden)
  end

  # The entry age gate, re-asked at the moment of a write. Eligibility is
  # stamped on the key at mint, but ENABLE_AGE_GATE can be turned on AFTER a key
  # was stamped `not_required`; the stamp cannot answer for that, the user row
  # can. Reads the same two facts as ApplicationController#age_verification_pending?.
  def age_gate_refusal
    return unless AppFlags.age_gate?
    return if current_user&.age_attested_at.present?

    Refusal.new(:age_verification_required, AGE_GATE_MESSAGE, :forbidden)
  end

  # Everything a write must clear, freeze first: it is the broader hold.
  def write_refusal
    frozen_account_refusal || age_gate_refusal
  end

  def require_unfrozen_account
    render_api_refusal(frozen_account_refusal)
  end

  def require_age_verified
    render_api_refusal(age_gate_refusal)
  end

  # GET and HEAD are the reads; every other verb is treated as a write.
  def refuse_frozen_account_writes
    return if request.get? || request.head?

    require_unfrozen_account
  end

  def render_api_refusal(refusal)
    return if refusal.nil?

    render_api_error(refusal.code, refusal.message, status: refusal.status)
  end

  def render_api_error(code, message, status:)
    render json: { error: { code: code.to_s, message: message } }, status: status
  end

  def render_api_auth_error(code)
    response.set_header("WWW-Authenticate", WWW_AUTHENTICATE)
    render_api_error(code, AUTH_ERRORS.fetch(code), status: :unauthorized)
  end

  # The exceptions an operation raises on purpose, as the Refusal each one is.
  # nil for anything else. REST renders the Refusal; a surface with its own
  # envelope (MCP) reads the same code and message from it.
  def api_exception_refusal(exception)
    case exception
    when ActiveRecord::RecordNotFound
      Refusal.new(:not_found, NOT_FOUND_MESSAGE, :not_found)
    when ActionController::ParameterMissing, ActionController::BadRequest
      Refusal.new(:bad_request, exception.message, :bad_request)
    end
  end

  def render_api_not_found(_exception = nil)
    render_api_error(:not_found, NOT_FOUND_MESSAGE, status: :not_found)
  end

  def render_api_bad_request(exception)
    render_api_refusal(api_exception_refusal(exception))
  end

  def render_api_malformed_body(_exception = nil)
    render_api_error(:bad_request, "The request body is not valid JSON.", status: :bad_request)
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
