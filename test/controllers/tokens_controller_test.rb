require "test_helper"
require "minitest/mock"

class TokensControllerTest < ActionDispatch::IntegrationTest
  setup do
    @alex = users(:alex)
    @jordan = users(:jordan)
  end

  test "buy requires login" do
    get tokens_buy_path
    assert_redirected_to signin_path
  end

  test "buy renders for logged in user" do
    log_in_as @jordan
    get tokens_buy_path
    assert_response :success
    assert_select "h1", text: /Entry Tokens/
  end

  test "dev_mint redirects non-admin with admin-only alert" do
    log_in_as @jordan
    post tokens_dev_mint_path, params: { pack: "single" }
    assert_redirected_to tokens_buy_path
    assert_match(/admin.*devnet/i, flash[:alert])
  end

  test "dev_mint creates requested quantity of on-chain tokens for an admin" do
    log_in_as @alex
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      post tokens_dev_mint_path, params: { pack: "trio" }
    end
    assert_redirected_to tokens_buy_path
    assert_match(/Minted 3 test tokens?/, flash[:notice])
    assert_equal 3, vault.mint_calls.length
    assert vault.mint_calls.all? { |r| r.start_with?("dev:") }
  end

  test "dev_mint rejects an unknown pack (kept — pure controller logic)" do
    log_in_as @alex
    post tokens_dev_mint_path, params: { pack: "bogus" }
    assert_redirected_to tokens_buy_path
  end

  test "stripe_checkout requires login" do
    post tokens_stripe_checkout_path, params: { pack: "single" }
    assert_redirected_to signin_path
  end

  test "stripe_checkout rejects an unknown pack" do
    log_in_as @jordan
    @jordan.update!(web2_solana_address: "TestWalletAddr123", encrypted_web2_solana_private_key: "x")
    post tokens_stripe_checkout_path, params: { pack: "bogus" }
    assert_redirected_to tokens_buy_path
    assert_match(/Unknown or unavailable/, flash[:alert])
  end

  test "stripe_checkout requires connected wallet" do
    log_in_as @jordan
    post tokens_stripe_checkout_path, params: { pack: "single" }
    assert_redirected_to tokens_buy_path
    assert_match(/Connect a wallet/, flash[:alert])
  end

  test "stripe_checkout redirects to Stripe session URL" do
    log_in_as @jordan
    @jordan.update!(web2_solana_address: "TestWalletAddr123", encrypted_web2_solana_private_key: "x")
    fake_session = Struct.new(:url).new("https://stripe.example/cs_test_xyz")
    with_stripe_enabled do
      Stripe::Checkout::Session.stub :create, fake_session do
        post tokens_stripe_checkout_path, params: { pack: "trio" }
      end
    end
    assert_redirected_to "https://stripe.example/cs_test_xyz"
  end

  # ── THE REFUSAL THAT HAPPENS BEFORE THE CHARGE ────────────────────────────
  #
  # TokenPurchaseJob mints AFTER the card is charged, and turf-vault v0.26 caps
  # mints per WINDOW: above the cap the same instruction needs three signatures
  # the server does not hold, so the failure persists for the rest of the window
  # rather than clearing on retry. Every remedy downstream of the charge is
  # cleanup on a customer who paid and got nothing, which is why the guard lives
  # here — the last point on the path where the money has not moved.

  def connected(user)
    user.update!(web2_solana_address: "TestWalletAddr123", encrypted_web2_solana_private_key: "x")
    user
  end

  test "stripe_checkout refuses BEFORE opening a payment page when the window cannot cover the pack" do
    log_in_as connected(@jordan)
    created = false
    with_stripe_enabled do
      Solana::Vault.stub :new, FakeVault.new(mint_window_remaining: 2) do
        Stripe::Checkout::Session.stub :create, ->(*) { created = true } do
          post tokens_stripe_checkout_path, params: { pack: "trio" } # 3 tokens, 2 slots left
        end
      end
    end

    refute created, "no checkout session may be created for tokens that cannot be minted"
    assert_redirected_to tokens_buy_path
    assert_match(/mint limit is reached/, flash[:alert])
    assert_match(/Nothing has been charged/, flash[:alert],
                 "the buyer must be told the one fact that matters to them")
  end

  # The control. A window with room is untouched — the guard must not become a
  # tax on every purchase, and it is inert entirely in the v0.25 shape, which is
  # what production runs today (FakeVault's default is no cap).
  test "stripe_checkout proceeds when the window has room for the whole pack" do
    log_in_as connected(@jordan)
    fake_session = Struct.new(:url).new("https://stripe.example/cs_test_room")
    with_stripe_enabled do
      Solana::Vault.stub :new, FakeVault.new(mint_window_remaining: 3) do
        Stripe::Checkout::Session.stub :create, fake_session do
          post tokens_stripe_checkout_path, params: { pack: "trio" } # 3 tokens, 3 slots left
        end
      end
    end
    assert_redirected_to "https://stripe.example/cs_test_room"
  end

  # FAILS OPEN. The count rides the same RPC everything else does; a blip is not
  # evidence the cap was reached, and refusing on ignorance would stop sales for
  # a reason that is not true. The job-side guard remains the backstop.
  test "stripe_checkout still sells when the window count cannot be read" do
    log_in_as connected(@jordan)
    fake_session = Struct.new(:url).new("https://stripe.example/cs_test_blind")
    blind = FakeVault.new
    blind.define_singleton_method(:mint_window_usage) { |*_a, **_k| raise IOError, "rpc unreachable" }
    with_stripe_enabled do
      Solana::Vault.stub :new, blind do
        Stripe::Checkout::Session.stub :create, fake_session do
          post tokens_stripe_checkout_path, params: { pack: "trio" }
        end
      end
    end
    assert_redirected_to "https://stripe.example/cs_test_blind"
  end

  test "stripe_checkout bounces with helpful alert when not configured" do
    log_in_as @jordan
    @jordan.update!(web2_solana_address: "TestWalletAddr123", encrypted_web2_solana_private_key: "x")
    with_stripe_disabled do
      post tokens_stripe_checkout_path, params: { pack: "single" }
    end
    assert_redirected_to tokens_buy_path
    assert_match(/Card checkout isn't configured/, flash[:alert])
  end

  test "stripe_checkout blocks a payment-risk-flagged user (OPSEC-036)" do
    log_in_as @jordan
    @jordan.update!(
      web2_solana_address: "TestWalletAddr123",
      encrypted_web2_solana_private_key: "x",
      payment_risk_flag: true
    )
    with_stripe_enabled do
      post tokens_stripe_checkout_path, params: { pack: "single" }
    end
    assert_redirected_to tokens_buy_path
    assert_match(/disabled on this account/, flash[:alert])
  end

  test "processing requires session_id" do
    log_in_as @jordan
    get tokens_processing_path
    assert_redirected_to tokens_buy_path
  end

  test "processing renders with session_id" do
    log_in_as @jordan
    get tokens_processing_path, params: { session_id: "cs_test_processing" }
    assert_response :success
  end

  # THE PARAMETER WAS THE LAST THING HOLDING THE BRANCH UP, so its removal is
  # asserted at the only place a caller could still reach it: the URL.
  #
  # `?preview_state=loading|ready|errored` forced this page into a static state
  # for the /admin/modals gallery's preview iframes. Those three variant URLs
  # were its only callers, and the gallery is gone. A query parameter has no
  # compile-time caller, though, so "nothing references it" is not "nothing
  # reaches it" — someone may hold the URL. What this pins is that the fallback
  # is the ORDINARY no-session redirect and not an error: the branch used to
  # suppress that redirect, so deleting it had to be shown to restore it rather
  # than to 500 the bookmark.
  test "processing ignores a stale preview_state and redirects when there is no session" do
    log_in_as @jordan
    %w[loading ready errored].each do |state|
      get tokens_processing_path, params: { preview_state: state }
      assert_redirected_to tokens_buy_path,
                           "?preview_state=#{state} with no session_id must fall through to the " \
                           "no-session redirect — a held bookmark degrades, it does not error"
    end
  end

  # The other half: the parameter must not survive as a live input on the path
  # that DOES render. A session_id hit renders the page, and the rendered Alpine
  # factory takes two arguments now — a third would mean the branch came back.
  test "processing renders no preview_state hook when a session is present" do
    log_in_as @jordan
    get tokens_processing_path, params: { session_id: "cs_test_processing", preview_state: "ready" }
    assert_response :success
    assert_no_match(/previewState/, response.body,
                    "the retired gallery preview hook is back in the rendered page")
    assert_match(/tokenProcessing\('cs_test_processing', ''\)/, response.body,
                 "tokenProcessing should take exactly (sessionId, contestUrl)")
  end

  test "status returns ready=false when no tokens for session" do
    log_in_as @jordan
    get tokens_status_path, params: { session_id: "cs_unknown" }
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal false, body["ready"]
    assert_equal 0, body["minted"]
  end

  test "status returns ready=true when StripePurchase is minted" do
    log_in_as @jordan
    sid = "cs_test_status_#{SecureRandom.hex(4)}"
    StripePurchase.create!(
      user: @jordan, stripe_session_id: sid,
      quantity: 1, price_cents: 19_00, status: "minted",
      mint_tx_signatures: ["sig_0"].to_json
    )
    get tokens_status_path, params: { session_id: sid }
    json = JSON.parse(response.body)
    assert json["ready"]
    assert_equal 1, json["minted"]
  end

  test "status scopes session_id to current_user — other users see ready=false" do
    sid = "cs_test_xuser_#{SecureRandom.hex(4)}"
    StripePurchase.create!(
      user: @alex, stripe_session_id: sid,
      quantity: 1, price_cents: 19_00, status: "minted",
      mint_tx_signatures: ["sig"].to_json
    )
    log_in_as @jordan
    get tokens_status_path, params: { session_id: sid }
    refute JSON.parse(response.body)["ready"]
  end

  private

  def with_stripe_enabled
    toggle_stripe(true) { yield }
  end

  def with_stripe_disabled
    toggle_stripe(false) { yield }
  end

  def toggle_stripe(value)
    original_enabled = Rails.application.config.x.stripe_enabled
    original_provider = Rails.application.config.x.payment_provider
    Rails.application.config.x.stripe_enabled = value
    Rails.application.config.x.payment_provider = "stripe"
    yield
  ensure
    Rails.application.config.x.stripe_enabled = original_enabled
    Rails.application.config.x.payment_provider = original_provider
  end
end
