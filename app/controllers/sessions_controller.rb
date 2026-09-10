# Pre-launch audit C3 (2026-05-24): cross-app SSO from McRitchie Studio is
# disabled in turf-monster. Cookie isolation (config/initializers/session_store.rb)
# already prevents the hub's session fields from being readable here, so
# `sso_continue` / `sso_login` would no-op anyway — but we 404 them explicitly
# for defense-in-depth. Non-SSO actions (`new` / `create` / `destroy`) mirror
# studio-engine's SessionsController. Restoring SSO means deleting this file +
# reverting session_store.rb + sessions/new.html.erb. See docs/AUTH.md.
class SessionsController < ApplicationController
  skip_before_action :require_authentication
  # An already-logged-in viewer has no business on the "Sign in to play" form —
  # bounce them to their account. Only the GET form render (:new), never the
  # POST create or the (404'd) SSO actions.
  before_action :redirect_if_authenticated, only: [:new]

  def new
  end

  # Passwordless: email auth is magic-link only (MagicLinksController). The
  # /login page no longer renders a password field; any POST that still lands
  # here (a stale form, a bot, a deep-link) is bounced to /login with a hint to
  # use the emailed link. Wallet auth (SolanaSessionsController) is unchanged.
  def create
    redirect_to signin_path, alert: "We use magic links — check your email for a sign-in link."
  end

  def sso_login
    head :not_found
  end

  def sso_continue
    head :not_found
  end

  def destroy
    # OPSEC-046: if an admin logs out WHILE impersonating (instead of clicking
    # "Return"), record the exit (reason: logout) and drop the impersonation
    # keys here, before the real-session wipe below. Captured first so true_user
    # / current_user still resolve. Plain begin/rescue (not rescue_and_log) for
    # the same reason the cart clear is — an audit hiccup must never strand a
    # user half-logged-out.
    if impersonating?
      begin
        ImpersonationLog.create!(
          action:      :exit,
          admin:       User.find_by(id: session[:true_admin_id]),
          target_user: current_user,
          reason:      "logout",
          ip:          request.remote_ip,
          user_agent:  request.user_agent
        )
      rescue => e
        Rails.logger.warn("[logout] impersonation exit log failed: #{e.message}")
      end
    end
    # Always drop the impersonation keys on logout — even if expired/inert — so
    # they can never linger in the cookie across a re-login (Avi NIT-2).
    session.delete(:impersonated_user_id)
    session.delete(:true_admin_id)
    session.delete(:impersonation_started_at)

    # Drop the user's in-progress cart so logging out leaves no stale picks
    # behind (the board's localStorage copy is cleared client-side on the
    # logout link too). Rescued so a cart-destroy hiccup can't 500 the logout.
    begin
      current_user&.entries&.cart&.destroy_all
    rescue => e
      Rails.logger.warn("[logout] cart clear failed: #{e.message}")
    end
    # ONE LINE INSTEAD OF TWO DENY-LISTS.
    #
    # This used to be `clear_app_session` (the engine's list of 3 + 7 sso_*
    # keys) followed by five more deletes by hand — two of which, :onchain and
    # :session_token, the engine had already deleted, because neither list could
    # see the other. Two hand-maintained enumerations of one set is the same
    # disease this whole audit is about, and it leaked: `wallet_setup`,
    # `wallet_setup_prompt`, `web3_step_up_prompt`, `onboarding_prompt`,
    # `onboarding_skipped_first_name`, `pending_google_link` and `oauth_popup`
    # all SURVIVED logout, because nobody had added them to either list.
    #
    # `reset_session` is an ALLOW-list of nothing: it rotates the session id and
    # drops every key, including the ones added next year by someone who never
    # reads this file. It is what magic_links_controller#reset_prior_session!
    # already does for a login by a DIFFERENT identity; logout has a strictly
    # stronger claim to it.
    #
    # ORDER MATTERS: everything above this line reads `current_user` or
    # `session[:true_admin_id]` (the impersonation audit row, the cart destroy),
    # so the wipe goes last. If you add work to this action, add it ABOVE.
    #
    # Nothing needs to survive a logout today. If something ever does, re-set it
    # explicitly BELOW this line so the exception is visible rather than implied
    # by its absence from a list.
    reset_session
    redirect_to signin_path, notice: "Logged out."
  end
end
