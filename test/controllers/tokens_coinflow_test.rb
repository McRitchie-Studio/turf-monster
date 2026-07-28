require "test_helper"
require "minitest/mock"

# Coinflow-rails onramp: TokensController#coinflow_order and the reference
# branch of #status. Mirrors the PayPal coverage in tokens_paypal_test.rb.
class TokensCoinflowTest < ActionDispatch::IntegrationTest
  setup do
    @alex = users(:alex)
    @jordan = users(:jordan)
  end

  # ── coinflow_order ────────────────────────────────────────────────────────

  test "coinflow_order requires login" do
    post tokens_coinflow_order_path, params: { pack: "single" }, as: :json
    assert_response :unauthorized
  end

  test "coinflow_order rejects an unknown pack" do
    log_in_as_with_wallet @jordan
    with_coinflow_enabled do
      post tokens_coinflow_order_path, params: { pack: "bogus" }, as: :json
    end
    assert_response :unprocessable_entity
    assert_match(/Unknown or unavailable/, JSON.parse(response.body)["error"])
  end

  test "coinflow_order requires a connected wallet" do
    log_in_as @jordan
    with_coinflow_enabled do
      post tokens_coinflow_order_path, params: { pack: "single" }, as: :json
    end
    assert_response :unprocessable_entity
    assert_match(/Connect a wallet/, JSON.parse(response.body)["error"])
  end

  test "coinflow_order refuses when the flag is off (deploy-inert gate)" do
    log_in_as_with_wallet @jordan
    with_coinflow_disabled do
      post tokens_coinflow_order_path, params: { pack: "single" }, as: :json
    end
    assert_response :unprocessable_entity
    assert_match(/isn't enabled/, JSON.parse(response.body)["error"])
    assert_equal 0, CoinflowPurchase.count
  end

  test "coinflow_order blocks a payment-risk-flagged user (OPSEC-036)" do
    log_in_as_with_wallet @jordan
    @jordan.update!(payment_risk_flag: true)
    with_coinflow_enabled do
      post tokens_coinflow_order_path, params: { pack: "single" }, as: :json
    end
    assert_response :forbidden
    assert_equal 0, CoinflowPurchase.count
  end

  test "coinflow_order blocks a frozen account (B4 / OPSEC-048)" do
    log_in_as_with_wallet @jordan
    @jordan.freeze_for_payment_risk!(reason: "test freeze")
    with_coinflow_enabled do
      post tokens_coinflow_order_path, params: { pack: "single" }, as: :json
    end
    assert_response :forbidden
    assert_equal 0, CoinflowPurchase.count
  end

  test "coinflow_order creates a pending purchase with SERVER-derived amount and returns the link + reference" do
    log_in_as_with_wallet @jordan
    client = FakeCoinflowClient.new(link: "https://sandbox-merchant.coinflow.cash/purchase-v2/HAPPY")
    with_coinflow_enabled do
      Coinflow::Client.stub :new, client do
        # price_cents is a decoy param — the server must ignore it and use the pack.
        post tokens_coinflow_order_path, params: { pack: "single", price_cents: 1 }, as: :json
      end
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "https://sandbox-merchant.coinflow.cash/purchase-v2/HAPPY", body["link"]
    assert body["reference"].present?

    purchase = CoinflowPurchase.for_reference(body["reference"]).first
    assert_equal @jordan.id, purchase.user_id
    assert_equal "single", purchase.pack_id
    assert_equal 1, purchase.quantity
    assert_equal 19_00, purchase.price_cents, "amount must come from the pack, never the client"
    assert_equal "pending", purchase.status
    assert_equal purchase.slug, purchase.coinflow_reference, "reference IS the slug"
    assert_equal @jordan.solana_address, purchase.wallet_address
    assert_equal 1, client.checkout_calls.length

    # The checkout link is asked for with the exact pack + the callback URL
    # carrying the reference for settlement resolution.
    call = client.checkout_calls.first
    assert_equal 19_00, call[:pack][:price_cents]
    assert_includes call[:return_url], "reference=#{purchase.coinflow_reference}"
  end

  test "coinflow_order records the contest context when given" do
    log_in_as_with_wallet @jordan
    contest = contests(:one)
    with_coinflow_enabled do
      Coinflow::Client.stub :new, FakeCoinflowClient.new do
        post tokens_coinflow_order_path, params: { pack: "single", contest: contest.slug }, as: :json
      end
    end
    assert_response :success
    reference = JSON.parse(response.body)["reference"]
    assert_equal contest.slug, CoinflowPurchase.for_reference(reference).first.contest_slug
  end

  test "coinflow_order marks the purchase failed when the Coinflow call raises" do
    log_in_as_with_wallet @jordan
    client = FakeCoinflowClient.new
    client.raises = "Coinflow down"
    with_coinflow_enabled do
      Coinflow::Client.stub :new, client do
        post tokens_coinflow_order_path, params: { pack: "single" }, as: :json
      end
    end
    assert_response :unprocessable_entity
    assert_equal "failed", CoinflowPurchase.last.status
  end

  # ── buy page card (flag-gated, additive) ──────────────────────────────────

  test "buy page offers a Coinflow card per pack when the flag is on" do
    log_in_as @jordan
    with_coinflow_enabled do
      get tokens_buy_path
    end
    assert_response :success
    assert_select "[data-coinflow-buy]"
    assert_match "window.tmCoinflowBuyOne", response.body, "the shared kickoff script must render"

    # EVERY purchasable pack gets a Coinflow card, not just the single — the
    # pack id rides through to /tokens/coinflow_order, and TokenPurchaseJob
    # mints pack[:quantity], so the trio card charges $49 and mints 3.
    StripePurchase.available_packs.each_key do |pack_id|
      assert_match "tmCoinflowBuyOne('#{pack_id}')", response.body,
                   "expected a Coinflow card for the #{pack_id} pack"
    end
    # Each card names its rail — the only on-card tell once Coinflow and Stripe
    # share the orb-glow shape.
    assert_select "[data-coinflow-buy] .provider-badge-coinflow",
                  count: StripePurchase.available_packs.size
  end

  test "buy page hides the Coinflow buy-1 card when the flag is off" do
    log_in_as @jordan
    with_coinflow_disabled { get tokens_buy_path }
    assert_response :success
    # Only the buy-page CARD is flag-gated. The Add Funds hub (a layout-level
    # modal) shows every rail in the test env, so its shared kickoff script is
    # present regardless — assert on the card marker, not the global function.
    assert_select "[data-coinflow-buy]", count: 0
    assert_no_match(/Buy 1 entry with Coinflow/, response.body)
  end

  # ── routing: format suffix must not sidestep the rack-attack throttle ──────

  test "coinflow endpoints reject a format suffix (throttles match exact paths)" do
    assert_equal "coinflow_order",
                 Rails.application.routes.recognize_path("/tokens/coinflow_order", method: :post)[:action]
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/tokens/coinflow_order.json", method: :post)
    end
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/webhooks/coinflow.json", method: :post)
    end
  end

  # ── status (reference branch) ─────────────────────────────────────────────

  test "status resolves a Coinflow purchase by reference" do
    purchase = create_pending_purchase(user: @jordan, reference: "coinflow_status")
    purchase.update!(status: "minted", mint_tx_signatures: ["sig_0"].to_json)
    log_in_as @jordan
    get tokens_status_path, params: { reference: "coinflow_status" }
    json = JSON.parse(response.body)
    assert json["ready"]
    assert_equal 1, json["minted"]
  end

  test "status scopes reference to current_user" do
    purchase = create_pending_purchase(user: @alex, reference: "coinflow_xuser")
    purchase.update!(status: "minted", mint_tx_signatures: ["sig"].to_json)
    log_in_as @jordan
    get tokens_status_path, params: { reference: "coinflow_xuser" }
    refute JSON.parse(response.body)["ready"]
  end

  private

  def log_in_as_with_wallet(user)
    user.update!(web2_solana_address: "TestWalletAddr#{SecureRandom.hex(3)}", encrypted_web2_solana_private_key: "x")
    log_in_as user
  end

  def create_pending_purchase(user:, reference:, pack_id: "single", quantity: 1, price_cents: 19_00)
    CoinflowPurchase.create!(
      user: user,
      coinflow_reference: reference,
      pack_id: pack_id,
      quantity: quantity,
      price_cents: price_cents,
      wallet_address: "TestWalletAddr#{SecureRandom.hex(3)}",
      status: "pending"
    )
  end

  def with_coinflow_enabled
    original = ENV["ENABLE_COINFLOW"]
    ENV["ENABLE_COINFLOW"] = "true"
    yield
  ensure
    original.nil? ? ENV.delete("ENABLE_COINFLOW") : ENV["ENABLE_COINFLOW"] = original
  end

  # Force the flag OFF regardless of a developer's local .env (which sets
  # ENABLE_COINFLOW=true to run the rail on the dev stack). The "deploy-inert"
  # tests must assert the off state deterministically, not rely on the ambient
  # env being unset.
  def with_coinflow_disabled
    original = ENV["ENABLE_COINFLOW"]
    ENV["ENABLE_COINFLOW"] = "false"
    yield
  ensure
    original.nil? ? ENV.delete("ENABLE_COINFLOW") : ENV["ENABLE_COINFLOW"] = original
  end
end
