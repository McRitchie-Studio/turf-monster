require "test_helper"

class MagicLinksControllerTest < ActionDispatch::IntegrationTest
  # These tests exercise the legal-age attestation gate as designed (ON).
  # The flag is parked off by default for the first contest; the off state
  # is covered in age_attestation_flag_test.rb.
  setup    { ENV["ENABLE_AGE_ATTESTATION"] = "true" }
  teardown { ENV.delete("ENABLE_AGE_ATTESTATION") }

  # ── request (POST /magic_link) ───────────────────────────────────────────
  test "create sends one magic-link email for a valid address" do
    assert_difference "EmailDelivery.count", 1 do
      post magic_link_request_path, params: { email: "newbie@example.com" }
    end
    assert_redirected_to signin_path
  end

  test "create sends no email for a malformed address but still responds success" do
    assert_no_difference "EmailDelivery.count" do
      post magic_link_request_path, params: { email: "not-an-email" }
    end
    assert_redirected_to signin_path
  end

  test "create responds JSON success for the modal" do
    assert_difference "EmailDelivery.count", 1 do
      post magic_link_request_path, params: { email: "modal@example.com" }, as: :json
    end
    assert_response :success
    assert JSON.parse(response.body)["success"]
  end

  # ── confirm interstitial (GET /magic_link/:token) ────────────────────────
  # The emailed link's GET is now a scanner-safe "Confirm sign-in" interstitial.
  # It MUST NOT consume the token or establish a session — email link-scanners,
  # the Gmail image proxy, and SafeLinks pre-fetch the URL, and if the GET
  # consumed the single-use token the human's first real click would already
  # see "link already used". The GET only renders a one-button page.
  test "confirm GET renders the interstitial WITHOUT consuming or signing in" do
    token = magic_token(email: "brand-new@example.com")
    assert_no_difference "User.count", "GET must not create the account (scanner pre-fetch)" do
      get magic_link_path(token: token)
    end
    assert_response :success
    assert_nil session[Studio.session_key], "GET must not establish a session"
    # The page offers the human a POST button back to the consume endpoint.
    assert_select "form[action=?][method=post]", magic_link_consume_path(token: token)
  end

  # A bogus token must never 500 and must never burn anything. Since the
  # Studio::LinkConsumption adoption the GET SETTLES an unusable token instead
  # of rendering a spinner that only POSTs to rediscover it — so the friendly
  # outcome is now a redirect rather than a 200. Both halves of the original
  # intent still hold, and the inertness is what actually mattered.
  test "confirm GET handles a bogus token without a 500 and without burning anything" do
    assert_no_difference -> { Studio::Link.where.not(consumed_at: nil).count } do
      get magic_link_path(token: "bogus.token.value")
    end

    assert_response :redirect
    assert_equal signin_path, URI.parse(response.location).path,
                 "a signed-out visitor with an unusable token belongs on the sign-in page"
  end

  # ── REGRESSION: a prefetch GET must NOT burn the single-use token ─────────
  # The core of the scanner-safe fix: only the human's POST consumes the link.
  # Single-use is a DB column now, so it's enforced directly — we simulate a
  # scanner pre-fetch (GET) and assert the human's later POST still signs in,
  # which can only happen if the GET left the link unconsumed.
  test "a scanner prefetch GET does not burn the token; the human's POST still signs in" do
    token = magic_token(email: users(:alex).email)

    # 1. Scanner / Gmail-proxy pre-fetches the emailed URL.
    get magic_link_path(token: token)
    assert_response :success
    assert_nil session[Studio.session_key], "the prefetch GET must not sign anyone in"

    # 2. The human clicks the button → POST consumes the still-live token.
    post magic_link_consume_path(token: token)
    assert_equal users(:alex).id, session[Studio.session_key],
                 "the human's POST must succeed — the GET must not have consumed the link"
  end

  # Single-use, asserted from a FRESH session. The property that matters is that
  # a spent token cannot let a STRANGER in — e.g. a forwarded email. Replaying
  # it as the SAME already-signed-in visitor is now deliberately a silent
  # redirect (see magic_link_reclick_test.rb): bouncing them to /signin while
  # they hold a valid session was the bug this app just fixed.
  test "single-use still holds: a spent token gets a fresh visitor nowhere" do
    token = magic_token(email: users(:alex).email)

    post magic_link_consume_path(token: token)
    assert_equal users(:alex).id, session[Studio.session_key]
    reset!

    post magic_link_consume_path(token: token)

    assert_redirected_to signin_path
    assert_nil session[Studio.session_key], "a replayed token must not sign a stranger in"
  end

  # ── consume (POST /magic_link/:token) ────────────────────────────────────
  # consume redirects to the LANDING page (return_to, else root); the post-auth
  # ONBOARDING CHAIN carries the greeting from there (first name -> age ->
  # wallet), armed one-shot on the session.
  #
  # The `flash[:magic_link_welcome]` modal this used to set is RETIRED (2026-08),
  # as is the chain's own `welcome` step (2026-08-15). The chain opens on the
  # first-name ask, outstanding by definition for an account created in this
  # request, which keeps that flash's only writer unreachable — so the assertions
  # below pin it as ABSENT rather than as an alternative path that still fires.
  test "consume creates a passwordless, email-verified account and arms the onboarding chain" do
    token = magic_token(email: "brand-new@example.com", age_attested: true)
    assert_difference "User.count", 1 do
      post magic_link_consume_path(token: token)
    end
    user = User.find_by(email: "brand-new@example.com")
    assert user.email_verified_at.present?, "new user should be email-verified by clicking the link"
    assert user.age_attested_at.present?, "new user should carry the legal-age attestation timestamp"
    # No contest return_to → a NEW generic signup lands on the ROOT board
    # (operator call, 2026-08-15; it used to resolve Contest.featured here).
    assert_redirected_to root_path
    assert_nil flash[:notice], "the greeting is a modal, not a toast"
    assert_nil flash[:auth_toast], "the chain greets; a toast would talk over it"
    assert_nil flash[:magic_link_welcome], "the chain's opening card replaces the flash modal here"
    # The chain is armed, and it OPENS on the first-name ask — no welcome beat in
    # front of it (retired 2026-08-15).
    assert_equal "first_name", session[:onboarding_prompt].first
    # Root redirects on to the live board — the destination the old inline
    # Contest.featured lookup produced directly.
    follow_redirect!
    assert_redirected_to contest_path(contests(:one))
  end

  # --- the auth pages are a way IN, never a place to arrive -------------------
  #
  # THE BUG (operator, 2026-08-15): a link requested from the sign-in card is
  # minted with return_to "/signin". Honoring that literally landed a
  # freshly-signed-in user back on /signin, where redirect_if_authenticated
  # bounced them to /account — so clicking a magic link put them on their account
  # page. Both halves are asserted: the redirect, and that FOLLOWING it stays put
  # (a landing that bounces is the whole defect, and the redirect alone can't see
  # it).
  test "a link that returns to the sign-in page lands on the root, not /account" do
    existing = users(:alex)
    existing.update_columns(first_name: "Mr.", age_attested_at: 30.years.ago,
                            web3_solana_address: "PhantomSigninReturn#{existing.id}")
    token = magic_token(email: existing.email, return_to: "/signin")
    post magic_link_consume_path(token: token)

    assert_redirected_to root_path
    # Root is contests#world_cup, a redirector to the live board, so ONE more hop
    # is expected and correct. What must never happen is landing back on an auth
    # page or on /account — that bounce IS the bug.
    follow_redirect!
    assert_not_equal account_path, request.path
    assert_not_equal signin_path, request.path
  end

  test "every auth path is treated as no destination at all" do
    # One rule, not a special case for /signin: /login, the magic-link pages and
    # the short /l/ links are all ways in.
    ["/signin", "/login", "/magic_link/abc", "/l/abc", "/"].each do |path|
      existing = users(:jordan)
      existing.update_columns(first_name: "Jo", age_attested_at: 30.years.ago,
                              web3_solana_address: "PhantomLoop#{existing.id}")
      post magic_link_consume_path(token: magic_token(email: existing.email, return_to: path))
      assert_redirected_to root_path, "return_to #{path} is a way in, not a landing"
      reset!
    end
  end

  test "consume lands a new signup on the contest return_to with an auth toast + tokens picker" do
    token = magic_token(email: "newpicker@example.com", return_to: "/contests/the-cup?picks=1,2,3", age_attested: true)
    post magic_link_consume_path(token: token)
    assert_redirected_to "/contests/the-cup?picks=1,2,3"
    # New user on a SPECIFIC contest: the return_to (with picks) is honored, and
    # the onboarding chain owns the greeting. The auth toast is suppressed while
    # the chain has anything to say — two greetings on one render reads as a bug.
    assert_nil flash[:magic_link_welcome]
    assert_nil flash[:auth_toast], "the chain speaks; the toast would talk over it"
    assert_equal "first_name", session[:onboarding_prompt].first
  end

  test "consume logs in an existing user on a safe return_to with a welcome-back toast" do
    existing = users(:alex)
    # This test is about the TOAST, so leave the onboarding chain nothing to ask:
    # a returning user who still owes a step is armed with the chain instead, and
    # the toast is deliberately suppressed then. The WALLET is part of "nothing to
    # ask" now — web3-only onboarding defaults ON (2026-08-15), and alex is an
    # admin, who never gets a managed wallet (OPSEC-044), so without a linked
    # Phantom the chain would still have the wallet step to open.
    existing.update_columns(first_name: "Mr.", age_attested_at: 30.years.ago,
                            web3_solana_address: "PhantomSettledToast#{existing.id}")
    token = magic_token(email: existing.email, return_to: "/account")
    assert_no_difference "User.count" do
      post magic_link_consume_path(token: token)
    end
    # An explicit non-contest return_to (e.g. /account) is still honored.
    assert_redirected_to "/account"
    assert_equal existing.id, session[Studio.session_key]
    # Returning login: a quiet welcome-back toast, no celebratory modal.
    assert_nil flash[:magic_link_welcome], "returning login should not show the welcome modal"
    toast = flash[:auth_toast]
    assert toast.present?, "returning login gets the welcome-back toast"
    assert_equal "Welcome back", toast[:title] || toast["title"]
  end

  test "consume verifies an existing but never-verified email" do
    existing = users(:alex)
    existing.update!(email_verified_at: nil)
    token = magic_token(email: existing.email)
    post magic_link_consume_path(token: token)
    assert existing.reload.email_verified_at.present?
  end

  # ── prior-session hard reset on consume ──────────────────────────────────
  # A magic link is a fresh WEB2 (email) login. If the browser already held a
  # web3/Phantom-signature session, none of its state may bleed into the new
  # one — that bleed is what made a web2 magic-link user still look web3 and
  # popped the Phantom unlock probe on the landing. consume must reset_session
  # + clear the :onchain privilege flag before establishing the new session.
  test "consume hard-resets a prior web3 session and lands the email user as web2" do
    onchain_user = users(:sam)
    log_in_as_onchain(onchain_user)
    assert_equal true, session[:onchain], "precondition: prior session is a live web3 session"

    email_user = users(:jordan)
    token = magic_token(email: email_user.email)
    post magic_link_consume_path(token: token)

    # New session belongs to the magic-link user, not the prior web3 user.
    assert_equal email_user.id, session[Studio.session_key]
    # The onchain privilege flag is gone — the new session is web2, not web3.
    assert_not session[:onchain], "onchain flag must not bleed into the magic-link session"

    # SessionContext for the new session reports web2 (onchain_session false).
    ctx = SessionContext.new(user: email_user, onchain_session: false)
    assert ctx.web2?, "magic-link email user should be web2"
    assert_not ctx.web3?
  end

  # Regression for PR #58: consume calls reset_session BEFORE set_app_session.
  # Application before_actions (notably detect_geo_state) write to session on
  # the SAME request that runs consume, so reset_session discards those prior
  # writes and rotates the session id mid-request. A brand-new signup must
  # still complete and land logged-in — the discarded geo keys are re-detected
  # next request and are not load-bearing for auth. (A friend tester clicking
  # the emailed link from a fresh browser is exactly this path.)
  test "consume creates + logs in the new user even when prior before-action session writes are present" do
    # Simulate the geo before_action having written to the session before
    # consume runs (the real detect_geo_state path). A prior consume establishes
    # + rotates a real session so the next consume runs with session writes
    # already present in the jar.
    post magic_link_consume_path(token: magic_token(email: "warmup@example.com", age_attested: true))
    # Now a genuinely new email; the jar already holds a rotated session.
    assert_difference "User.count", 1 do
      post magic_link_consume_path(token: magic_token(email: "fresh-browser@example.com", age_attested: true))
    end
    user = User.find_by(email: "fresh-browser@example.com")
    assert_equal user.id, session[Studio.session_key], "new user must be logged in after reset_session"
    assert user.email_verified_at.present?
    assert user.username.present?, "auto-generated username must be set"
    assert_not session[:onchain], "a magic-link signup is web2, not web3"
  end

  # Regression for PR #58: clicking a magic link for a NEW email while already
  # logged in as a DIFFERENT user must switch the session to the new user with
  # no identity bleed from the prior session.
  test "consume for a new email while logged in as another user switches the session cleanly" do
    prior = users(:alex)
    log_in_as(prior)
    assert_equal prior.id, session[Studio.session_key], "precondition: logged in as the prior user"

    token = magic_token(email: "switcheroo@example.com", age_attested: true)
    assert_difference "User.count", 1 do
      post magic_link_consume_path(token: token)
    end
    switched = User.find_by(email: "switcheroo@example.com")
    assert_not_equal prior.id, session[Studio.session_key]
    assert_equal switched.id, session[Studio.session_key], "session must belong to the new user, not the prior one"
  end

  test "consume rejects an invalid token" do
    post magic_link_consume_path(token: "bogus.token.value")
    assert_redirected_to signin_path
  end

  test "consume sanitizes a protocol-relative return_to (open-redirect guard)" do
    token = magic_token(email: users(:alex).email, return_to: "//evil.com/x")
    post magic_link_consume_path(token: token)
    # The evil path is dropped to nil → falls back to the safe in-app root.
    assert_redirected_to root_path
  end

  # ── legal-age attestation (underwriting compliance) ───────────────────────
  # A brand-new account may only be created when the link request carried the
  # legal-age attestation (the checkbox on the auth card / auth modal). The
  # attestation rides in the magic-link row; consume is the enforcement point.
  test "consume REFUSES to create an account without the legal-age attestation" do
    token = magic_token(email: "underage-unknown@example.com")
    assert_no_difference "User.count" do
      post magic_link_consume_path(token: token)
    end
    assert_redirected_to signin_path
    assert_match(/legal age/i, flash[:alert])
    assert_nil session[Studio.session_key], "no session may be established"
  end

  test "create threads the age_attestation param into the magic-link row" do
    post magic_link_request_path, params: { email: "attest@example.com", age_attestation: "1" }
    assert magic_link_for("attest@example.com").age_attested?,
           "the request checkbox must persist onto the link row"

    post magic_link_request_path, params: { email: "no-attest@example.com" }
    assert_not magic_link_for("no-attest@example.com").age_attested?,
               "absent checkbox must not be treated as attested"
  end

  test "existing users still log in via links that carry no attestation (grandfathered)" do
    existing = users(:alex)
    assert_nil existing.age_attested_at
    token = magic_token(email: existing.email)
    post magic_link_consume_path(token: token)
    assert_equal existing.id, session[Studio.session_key],
                 "login is unaffected — attestation gates account CREATION only"
  end

  # Carry-forward of the deleted MagicLink service test: a link past its TTL is
  # rejected on consume (Studio::Link expiry).
  test "an expired magic link is rejected on consume" do
    token = magic_token(email: "expired-ml@example.com")
    travel(Studio.magic_link_ttl + 1.minute) do
      assert_no_difference "User.count" do
        post magic_link_consume_path(token: token)
      end
    end
    assert_redirected_to signin_path
    assert_nil session[Studio.session_key]
    # The message rides in auth_toast now, because that is the only flash this
    # app renders — a :alert here would have been invisible to the visitor.
    toast = flash[:auth_toast]&.with_indifferent_access
    refute_nil toast, "an expired link must SAY so, in the channel turf actually renders"
    assert_match(/expired/i, toast[:message])
  end
end
