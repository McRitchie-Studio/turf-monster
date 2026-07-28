require "test_helper"
require "minitest/mock"

class AccountsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @alex = users(:alex)
  end

  test "show requires login" do
    get account_path
    assert_redirected_to signin_path
  end

  test "account page shows a Buy Entry Token button linking to the entry-token buy page" do
    # A wallet-connected user renders the wallet-actions row (Buy USDC / Buy Entry
    # Token / Refresh). Stamp a managed wallet so solana_connected? is true.
    @alex.update!(web2_solana_address: "TestWalletAddr#{SecureRandom.hex(3)}", encrypted_web2_solana_private_key: "x")
    log_in_as @alex
    get account_path
    assert_response :success
    assert_select "a[data-testid='buy-entry-token'][href=?]", tokens_buy_path
    assert_select "a[data-testid='buy-entry-token']", text: /Buy Entry Token/
  end

  test "save_profile saves and redirects to root" do
    log_in_as @alex
    post save_profile_account_path, params: { user: { name: "ignored" } }
    assert_redirected_to root_path
  end

  test "save_profile rejects a non-image avatar" do
    log_in_as @alex
    post save_profile_account_path, params: { user: { avatar: fixture_file_upload("not_an_image.txt", "text/plain") } }
    assert_response :unprocessable_entity
    assert_not @alex.reload.avatar.attached?
  end

  # --- session_state tests ---

  test "session_state returns guest shape for unauthenticated callers" do
    get session_state_account_path, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "guest", body["mode"]
    assert_equal false, body["loggedIn"]
    assert_nil body["userId"]
    assert_equal "", body["address"]
    assert body["csrf"].present?, "expected a fresh CSRF token in the response"
  end

  test "session_state carries usdcCents / usdtCents / tokensAvailable for guests" do
    # The synchronous entry-eligibility check (window.eligibilityBlocker)
    # reads these three fields off $store.session and assumes they exist.
    # Guests have no wallet at all — emit definitive 0s, not the null
    # "preload flaked" signal that only applies to logged-in users.
    get session_state_account_path, as: :json
    body = JSON.parse(response.body)
    assert_equal 0, body["usdcCents"]
    assert_equal 0, body["usdtCents"]
    assert_equal 0, body["tokensAvailable"]
  end

  test "client_session_payload converts uiAmount dollars to integer cents" do
    # Direct check of the conversion math + the cache-first tokensAvailable —
    # inject @wallet_balances for cents, and warm the entry-tokens cache for the
    # count. Neither goes through an RPC (mirrors the cache-first render
    # contract; test env is :null_store, so inject a MemoryStore for the read).
    user = users(:sam) # web3_solana_address fixture → solana_connected?
    ctl = ApplicationController.new
    ctl.instance_variable_set(:@wallet_balances, { usdc: 12.34, usdt: 0.5, sol: 1.0 })
    ctl.define_singleton_method(:current_user)     { user }
    ctl.define_singleton_method(:onchain_session?) { false }

    payload = Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
      Rails.cache.write(Solana::Vault.entry_tokens_cache_key(user.solana_address),
                        [{ consumed: false }, { consumed: true }, { consumed: false }, { consumed: false }])
      ctl.send(:client_session_payload)
    end
    assert_equal 1234, payload[:usdcCents],
                 "12.34 USDC should round to 1234 cents"
    assert_equal 50,   payload[:usdtCents],
                 "0.5 USDT should round to 50 cents"
    assert_equal 3,    payload[:tokensAvailable],
                 "warm entry-tokens cache → non-consumed count (cache-first, no RPC)"
    # SessionContext identity fields still present.
    assert_equal user.id, payload[:userId]
    assert payload[:loggedIn]
  end

  test "session_state emits null usdcCents/usdtCents when preload nil'd (flake signal)" do
    # client_session_payload reads its on-chain fields CACHE-FIRST. With no
    # preloaded @wallet_balances and a cold cache, usdcCents / usdtCents emit
    # null so the client recognises "unknown" and fails open in the eligibility
    # check. tokensAvailable comes from display_entry_token_count; @alex is a
    # non-wallet (email) user, so it's the definitive 0 (an Integer) here.
    log_in_as @alex
    get session_state_account_path, as: :json
    body = JSON.parse(response.body)
    assert body.key?("usdcCents"),       "expected usdcCents key in payload"
    assert body.key?("usdtCents"),       "expected usdtCents key in payload"
    assert body.key?("tokensAvailable"), "expected tokensAvailable key in payload"
    # session_state is JSON (the preload before_action is HTML-only) → no
    # @wallet_balances → null cents. A non-wallet user's token count is 0.
    assert_nil body["usdcCents"], "expected null when @wallet_balances is nil"
    assert_nil body["usdtCents"], "expected null when @wallet_balances is nil"
    assert_equal 0, body["tokensAvailable"], "non-wallet user → definitive 0"
  end

  test "session_state returns web2 shape for an email-logged-in user" do
    log_in_as @alex
    get session_state_account_path, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "web2", body["mode"]
    assert_equal true, body["loggedIn"]
    assert_equal @alex.id, body["userId"]
    assert body["csrf"].present?
  end

  test "session_state returns web3 shape after a Phantom login" do
    user = User.create!(email: "phantom@mcritchie.studio")
    log_in_as_onchain(user)
    get session_state_account_path, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "web3", body["mode"]
    assert_equal true, body["loggedIn"]
    assert_equal user.id, body["userId"]
    assert_equal user.reload.web3_solana_address, body["address"]
  end

  test "session_state skips require_profile_completion gate" do
    user = User.create!(email: "incomplete@mcritchie.studio")
    # User with no username would normally hit require_profile_completion and
    # get redirected; session_state must be reachable for the visibilitychange
    # rehydrate hook to work even mid-onboarding.
    user.update_column(:username, nil)
    log_in_as user
    get session_state_account_path, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["loggedIn"]
  end

  # --- update_username tests ---

  test "update_username rejects a taken username" do
    # Must satisfy can_change_username? (wallet + entered) to reach the
    # validation check; otherwise the gate intercepts first with 403.
    @alex.update_columns(web2_solana_address: "test_wallet_alex_111", contest_entered: true)
    log_in_as @alex
    post update_username_account_path, params: { value: users(:jordan).username }, as: :json
    assert_response :unprocessable_entity
    assert_equal "error", JSON.parse(response.body)["status"]
  end

  test "update_username (custodial) saves via a server-signed set_username" do
    user = User.create!(email: "renamer@mcritchie.studio") # managed wallet
    user.update_columns(contest_entered: true) # satisfy the gate
    log_in_as user
    fake_vault = Object.new
    def fake_vault.set_username(*, **)
      { signature: "sig_test" }
    end
    Solana::Vault.stub :new, fake_vault do
      post update_username_account_path, params: { value: "renamed-fox" }, as: :json
    end
    assert_response :success
    assert_equal "saved", JSON.parse(response.body)["status"]
    assert_equal "renamed-fox", user.reload.username
  end

  test "update_username is gated until contest_entered" do
    user = User.create!(email: "gated@mcritchie.studio") # managed wallet, contest_entered: false
    log_in_as user
    post update_username_account_path, params: { value: "new-name-here" }, as: :json
    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_equal "error", body["status"]
    assert_match(/Enter a contest first/i, body["message"])
    assert_equal user.username, user.reload.username, "username should not have changed"
  end

  test "update_username rejects when no wallet (gate fail-closed)" do
    user = User.create!(email: "nowallet@mcritchie.studio")
    user.update_columns(web2_solana_address: nil, web3_solana_address: nil, contest_entered: true)
    log_in_as user
    post update_username_account_path, params: { value: "new-name" }, as: :json
    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_match(/No wallet/i, body["message"])
  end

  test "show renders for logged in user" do
    log_in_as @alex
    get account_path
    assert_response :success
  end

  test "update changes name" do
    log_in_as @alex
    patch account_path, params: { user: { name: "New Name" } }
    assert_redirected_to account_path
    @alex.reload
    assert_equal "New Name", @alex.name
  end

  test "update attaches a valid avatar" do
    log_in_as @alex
    assert_changes -> { @alex.reload.avatar.attached? }, from: false, to: true do
      patch account_path, params: { user: { avatar: fixture_file_upload("banner.png", "image/png") } }
    end
    assert_redirected_to account_path
  end

  test "update rejects a non-image avatar and does not attach" do
    log_in_as @alex
    patch account_path, params: { user: { avatar: fixture_file_upload("not_an_image.txt", "text/plain") } }
    assert_redirected_to account_path
    assert_not @alex.reload.avatar.attached?
  end

  test "unlink_google clears provider and uid" do
    @alex.update!(provider: "google_oauth2", uid: "12345")
    log_in_as @alex
    post unlink_google_account_path
    assert_redirected_to account_path
    @alex.reload
    assert_nil @alex.provider
    assert_nil @alex.uid
  end

  # Passwordless (Lazarus audit #4): the change_password action + route are
  # gone entirely. Email auth is magic-link only. The named route helper no
  # longer exists (NameError), and a raw POST to the old path 404s.
  test "change_password route helper is gone" do
    assert_raises(NameError) do
      change_password_account_path
    end
  end

  test "POST to the old change_password path 404s (route removed)" do
    log_in_as @alex
    post "/account/change_password", params: { new_password: "x" }
    assert_response :not_found
  end

  # OPSEC-007: update_level route + action removed. Previously accepted
  # client-supplied seeds_total which trivially inflated user level. Level
  # is now read directly from on-chain seeds (cached navbar localStorage
  # is populated from the server's authoritative confirm_onchain_entry
  # response). No replacement test needed — there's no longer a write path.

  test "stale session_token boots the request (OPSEC-045)" do
    log_in_as @alex
    # Simulate a stale cookie: another session rotated the user's token
    # (e.g., the user just changed password from a different device).
    @alex.update_column(:session_token, SecureRandom.hex(32))

    get account_path
    assert_redirected_to signin_path
  end

  # --- Out-of-band email change (Lazarus audit #4) ---

  # Changing an EXISTING email does not apply it in-session; it sends a confirm
  # link to the current address and leaves the email unchanged.
  test "changing an existing email leaves it UNCHANGED and sends a confirm link" do
    @alex.update!(email_verified_at: Time.current)
    current_email = @alex.email
    log_in_as @alex

    assert_difference "EmailDelivery.count", 1 do
      patch account_path, params: { user: { email: "newaddr@example.com" } }
    end
    assert_redirected_to account_path
    @alex.reload
    assert_equal current_email, @alex.email, "email must not change until OOB confirm"
    assert @alex.email_verified_at.present?, "verified_at unchanged until confirm"
    # The success presentation is now an informational MODAL, signalled via
    # flash[:email_change_pending] (carrying the emails the modal renders),
    # NOT a flash[:notice] toast. (with_indifferent_access: the in-request
    # FlashHash keeps symbol keys; through a real cookie round-trip they're
    # strings — the view reads it with_indifferent_access for the same reason.)
    pending = flash[:email_change_pending].with_indifferent_access
    assert pending.present?, "expected the email-change-pending modal signal in the flash"
    assert_equal current_email, pending[:current_email]
    assert_equal "newaddr@example.com", pending[:new_email]
    # No held-change :notice is SET by the update action (the modal replaces
    # the toast). A pre-existing login notice may still be sticky in the test
    # session, so we assert the held-change copy specifically is absent rather
    # than the whole :notice slot.
    refute_match(/Confirm the change|link we sent/i, flash[:notice].to_s,
                 "modal replaces the toast — no held-change :notice")
  end

  # The held-change response signals the email-change-pending modal (not a
  # toast): flash[:email_change_pending] present with the current + new emails
  # so the /account page can render them into the modal via x-text.
  test "held email change sets the modal signal with the current and new emails" do
    @alex.update!(email_verified_at: Time.current)
    current_email = @alex.email
    log_in_as @alex

    patch account_path, params: { user: { email: "modal-signal@example.com" } }
    assert_redirected_to account_path
    pending = flash[:email_change_pending].with_indifferent_access
    assert pending.present?, "expected flash[:email_change_pending] on a held change"
    assert_equal current_email,              pending[:current_email]
    assert_equal "modal-signal@example.com", pending[:new_email]

    # And the /account page renders the modal trigger markup from that flash.
    follow_redirect!
    assert_response :success
    assert_match(/email-change-pending-data/, response.body,
                 "expected the JSON trigger script tag on the account page")
    assert_match(/email-change-pending/, response.body,
                 "expected the auto-open call referencing the modal id")
    assert_match(/modal-signal@example\.com/, response.body,
                 "expected the new email in the modal trigger payload")
  end

  # First-email + plain-update branches keep their flash[:notice] toast — the
  # modal swap is ONLY for the held existing-email change.
  test "setting a first email still uses a flash notice (not the modal)" do
    user = User.create!(web3_solana_address: Solana::Keypair.generate.address)
    user.update_columns(email: nil, email_verified_at: nil)
    log_in_as_onchain(user)
    patch account_path, params: { user: { email: "firsttoast@example.com" } }
    assert_match(/Verify your new email/i, flash[:notice].to_s,
                 "first-email change keeps its verify toast")
    assert_nil flash[:email_change_pending], "first-email change must not trigger the modal"
  end

  test "a non-email update still uses a flash notice (not the modal)" do
    log_in_as @alex
    patch account_path, params: { user: { name: "Toast Name" } }
    assert_match(/Account updated/i, flash[:notice].to_s,
                 "plain update keeps its Account updated toast")
    assert_nil flash[:email_change_pending], "plain update must not trigger the modal"
  end

  # The confirm mail goes to the CURRENT (pre-change) address — that's the OOB
  # control that closes the hijacked-session → silent-email-swap chain.
  test "email-change confirm mail is sent to the current address" do
    @alex.update!(email_verified_at: Time.current)
    current_email = @alex.email
    log_in_as @alex

    patch account_path, params: { user: { email: "attacker@example.com" } }
    perform_enqueued_jobs
    mail = ActionMailer::Base.deliveries.last
    assert_equal [current_email], mail.to
    assert_match(/confirm/i, mail.subject)
  end

  # Other fields (name) still save even when the email change is held for OOB confirm.
  test "name still saves alongside a held email change" do
    @alex.update!(email_verified_at: Time.current)
    log_in_as @alex
    patch account_path, params: { user: { name: "Renamed Person", email: "held@example.com" } }
    @alex.reload
    assert_equal "Renamed Person", @alex.name
    assert_not_equal "held@example.com", @alex.email
  end

  # Setting the FIRST email (no prior address) applies directly + unverified.
  test "setting a first email applies directly and clears verified_at" do
    user = User.create!(web3_solana_address: Solana::Keypair.generate.address)
    user.update_columns(email: nil, email_verified_at: nil)
    log_in_as_onchain(user)
    patch account_path, params: { user: { email: "first@example.com" } }
    user.reload
    assert_equal "first@example.com", user.email
    assert_nil user.email_verified_at
  end

  # The GET confirm link only RENDERS an interstitial — it must NOT mutate.
  # A link prefetcher / mail scanner issuing the GET cannot apply the change.
  test "GET confirm_email_change renders the interstitial without changing the email" do
    @alex.update!(email_verified_at: Time.current)
    original = @alex.email
    token = email_change_token(@alex, "interstitial@example.com", @alex.email)

    get confirm_email_change_path(token: token)
    assert_response :success
    @alex.reload
    assert_equal original, @alex.email, "GET must not apply the change — POST does"
    assert @alex.email_verified_at.present?, "GET must not touch verification state"
  end

  # apply_email_change (POST) with a valid token applies the new email + rotates
  # the session token (boots any other session, e.g. a hijacker's).
  test "apply_email_change applies the new email and rotates session_token" do
    @alex.update!(email_verified_at: Time.current)
    token = email_change_token(@alex, "confirmed@example.com", @alex.email)
    before_token = @alex.session_token

    post apply_email_change_path(token: token)
    @alex.reload
    assert_equal "confirmed@example.com", @alex.email
    assert_nil @alex.email_verified_at, "new address must be re-verified"
    assert_not_equal before_token, @alex.session_token, "session token must rotate on confirm"
  end

  test "apply_email_change enqueues a verification mail for the new address" do
    @alex.update!(email_verified_at: Time.current)
    token = email_change_token(@alex, "verifyme@example.com", @alex.email)
    # apply now sends TWO: the OPSEC heads-up to the old address + the
    # verification link to the new one.
    assert_difference "EmailDelivery.count", 2 do
      post apply_email_change_path(token: token)
    end
  end

  # POST apply must also reject a stale token (token re-verified at submit time,
  # not just at render) — closes the render-then-go-stale gap.
  test "apply_email_change rejects a stale token (410)" do
    @alex.update!(email: "moved2@example.com", email_verified_at: Time.current)
    token = email_change_token(@alex, "newer2@example.com", "old2@example.com")
    post apply_email_change_path(token: token)
    assert_response :gone
    @alex.reload
    assert_equal "moved2@example.com", @alex.email
  end

  # A stale token (current_email no longer matches) is rejected with 410.
  test "confirm_email_change rejects a stale token (email already changed)" do
    @alex.update!(email: "moved@example.com", email_verified_at: Time.current)
    # Token minted against the OLD address — now stale.
    token = email_change_token(@alex, "newer@example.com", "old-address@example.com")
    get confirm_email_change_path(token: token)
    assert_response :gone
    @alex.reload
    assert_equal "moved@example.com", @alex.email
  end

  test "confirm_email_change rejects an invalid/garbage token (410)" do
    get confirm_email_change_path(token: "not-a-real-token")
    assert_response :gone
  end

  # The full Lazarus audit #4 chain: a logged-in (possibly hijacked) session
  # cannot silently change the email — it's held for OOB confirm — and the
  # wallet-export key reveal is reachable only behind the verified email +
  # emailed token, never via in-session re-auth.
  test "logged-in session cannot silently change email (audit #4)" do
    @alex.update!(email_verified_at: Time.current)
    original = @alex.email
    log_in_as @alex
    patch account_path, params: { user: { email: "takeover@example.com" } }
    @alex.reload
    assert_equal original, @alex.email, "email change must require OOB confirmation"
  end

  test "non-email update (name only) applies normally" do
    log_in_as @alex
    patch account_path, params: { user: { name: "Different Name" } }
    assert_redirected_to account_path
    @alex.reload
    assert_equal "Different Name", @alex.name
  end

  private

  def email_change_token(user, new_email, current_email)
    Rails.application.message_verifier(AccountsController::EMAIL_CHANGE_TOKEN_KEY).generate(
      { user_id: user.id, new_email: new_email, current_email: current_email, requested_at: Time.current.to_i },
      expires_in: 30.minutes
    )
  end
end
