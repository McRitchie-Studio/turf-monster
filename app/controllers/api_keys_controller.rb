# Mint and revoke agent API keys from /account (docs/AGENT_API.md).
#
# THIS IS WHERE ELIGIBILITY IS DECIDED. An API request arrives from an agent's
# servers, so nothing about it says where the player is or how old they are.
# The one moment we can know is here: the player's own browser, signed in,
# asking for a key. Every gate a contest entry runs is run now, server-side,
# and the verdict is stamped on the key (ApiKey#eligibility):
#
#   * geo — `require_geo_allowed`, the same engine gate ContestsController
#     hangs on entry, reading the same session-cached lookup of this request's
#     IP. Fail-closed on an unplaceable visitor, as everywhere else.
#   * age — when ENABLE_AGE_GATE is on, the player must already have verified
#     a date of birth (age_attested_at). Flag off, the stamp says not_required.
#
# Hiding the button is a courtesy; these before_actions are the boundary.
class ApiKeysController < ApplicationController
  AGE_PENDING_MESSAGE = "Verify your age before creating an API key.".freeze
  IMPERSONATION_MESSAGE = "API keys can't be created while acting as another user.".freeze

  # OPSEC-046: a key minted mid-impersonation would be PERSISTENT access to the
  # target that survives "Return" — the same reason AccountsController refuses
  # identity changes. Revoking stays allowed: it only ever removes access.
  before_action :refuse_mint_while_impersonating, only: :create
  before_action :require_unfrozen_account, only: :create
  before_action :require_geo_allowed, only: :create
  before_action :require_age_verified, only: :create

  # Renders the key ONCE, in the response to this POST. It is not put in the
  # flash (that would write it to the session cookie) and not redirected to a
  # URL that could show it again. Leave the page and it is gone.
  def create
    limit_error = nil
    rescue_and_log(target: current_user) do
      @api_key = ApiKey.mint!(
        user: current_user,
        name: params[:name],
        geo_country: geo_country,
        geo_state: geo_state,
        age_result: age_gate_required? ? "passed" : "not_required"
      )
    rescue ApiKey::LimitReached => e
      # A player at their cap is not an incident; keep it out of error_logs.
      limit_error = e.message
    end
    return redirect_to account_path, alert: limit_error, status: :see_other if limit_error

    response.headers["Cache-Control"] = "no-store"
    render :create, status: :created
  rescue StandardError
    redirect_to account_path, alert: "Could not create an API key. Please try again.", status: :see_other
  end

  # Scoped through current_user, so another player's key id is a 404, not a
  # revoke.
  def destroy
    api_key = current_user.api_keys.find(params[:id])
    rescue_and_log(target: current_user) do
      api_key.revoke!
    end
    redirect_to account_path, notice: "API key #{api_key.prefix}… revoked.", status: :see_other
  rescue ActiveRecord::RecordNotFound
    raise
  rescue StandardError
    redirect_to account_path, alert: "Could not revoke that key. Please try again.", status: :see_other
  end

  private

  def refuse_mint_while_impersonating
    return unless impersonating?

    redirect_to account_path, alert: IMPERSONATION_MESSAGE, status: :see_other
  end

  def require_age_verified
    return unless age_verification_pending?

    redirect_to account_path, alert: AGE_PENDING_MESSAGE, status: :see_other
  end
end
