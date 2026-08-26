require "test_helper"

# REQUIREMENT 6 — "Logout is a start-from-scratch button and should behave like
# one." Before this slice it did not: SessionsController#destroy carried TWO
# hand-maintained deny-lists (the engine's `clear_app_session` plus five more
# deletes here), neither of which could see the other, and seven keys walked
# straight through both.
#
# THE POINT OF THIS FILE is that it is written against the WHOLE KEY SET, not
# against the seven that happened to leak. A deny-list passes a test that names
# the keys it already knows about; that is exactly how those seven survived. So
# the assertion below is "the session is EMPTY of anything user-bound", which a
# future eighth key cannot slip past.
class LogoutIsDefinitiveTest < ActionDispatch::IntegrationTest
  # Every session key this app writes, derived 2026-08-26 and pinned here so a
  # NEW one added without a thought for logout shows up as a failure.
  #
  # `wallet_brand` is the one a grep cannot find: it is written as
  # `session[SESSION_KEY]` (Solana::CurrentWallet::SESSION_KEY), so a
  # `session[:literal]` sweep misses it. It was missing from the audit's first
  # inventory for exactly that reason. Resolve constants when you re-derive.
  USER_BOUND_SESSION_KEYS = %i[
    onchain session_token solana_nonce solana_nonce_at return_to
    wallet_setup wallet_setup_prompt web3_step_up_prompt
    onboarding_prompt onboarding_skipped_first_name
    pending_google_link oauth_popup
    impersonated_user_id true_admin_id impersonation_started_at
  ].freeze

  test "logout leaves nothing user-bound in the session" do
    user = users(:alex)
    log_in_as_onchain(user)
    assert session[:onchain], "precondition: the wallet login set the onchain flag"

    # Dirty the session with every key this app is known to write, including the
    # ones the old deny-lists never mentioned.
    USER_BOUND_SESSION_KEYS.each { |k| session[k] ||= "dirty" }
    session[Solana::CurrentWallet::SESSION_KEY] = "phantom"

    get logout_path
    assert_redirected_to signin_path

    leaked = USER_BOUND_SESSION_KEYS.select { |k| session[k].present? }
    assert_empty leaked,
                 "these session keys survived logout: #{leaked.inspect}. Logout is a " \
                 "start-from-scratch button — a key that outlives it is inherited by " \
                 "whoever logs in next in this browser."

    assert_nil session[Solana::CurrentWallet::SESSION_KEY],
               "the wallet brand is written through a CONSTANT key, so a deny-list built " \
               "from a session[:literal] grep cannot see it. reset_session does."
  end

  test "a second user logging in inherits nothing from the first" do
    first = users(:alex)
    log_in_as_onchain(first)
    first_id = session[:turf_user_id]
    assert session[:onchain], "precondition: user one holds an onchain session"

    get logout_path

    second = users(:sam)
    log_in_as second

    refute_equal first_id, session[:turf_user_id], "precondition: a different user is signed in"
    assert_nil session[:onchain],
               "user two must NOT inherit user one's onchain privilege. That flag gates " \
               "whether this session can sign on-chain, so inheriting it is not cosmetic."
    assert_nil session[Solana::CurrentWallet::SESSION_KEY],
               "nor user one's wallet brand"
  end

  # NOT YET WRITTEN — the ordering guard.
  #
  # reset_session runs LAST in #destroy because everything above it reads
  # current_user or session[:true_admin_id]: the impersonation audit row and the
  # cart destroy. A refactor that moves the wipe up would silently stop writing
  # that ImpersonationLog row (OPSEC-046) and no test here would notice.
  #
  # The test was drafted and pulled: admin_impersonate_path needs a target with
  # a slug and the fixtures do not carry one, so it needs a slug backfill or a
  # created record rather than users(:sam). Left as a NAMED hole rather than a
  # green suite that implies coverage it does not have.
end
