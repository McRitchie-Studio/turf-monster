require "test_helper"
require "minitest/mock"

# Aeropay-rails onramp: TokensController#aeropay_order and the aeropay_reference
# branch of #status. Mirrors the Coinflow coverage in tokens_coinflow_test.rb.
class TokensAeropayTest < ActionDispatch::IntegrationTest
  setup do
    @alex = users(:alex)
    @jordan = users(:jordan)
  end

  # ── aeropay_order ─────────────────────────────────────────────────────────

  test "aeropay_order requires login" do
    post tokens_aeropay_order_path, params: { pack: "single", bank_account_id: "bank_1" }, as: :json
    assert_response :unauthorized
  end

  test "aeropay_order rejects an unknown pack" do
    log_in_as_with_wallet @jordan
    with_aeropay_enabled do
      post tokens_aeropay_order_path, params: { pack: "bogus", bank_account_id: "bank_1" }, as: :json
    end
    assert_response :unprocessable_entity
    assert_match(/Unknown or unavailable/, JSON.parse(response.body)["error"])
  end

  test "aeropay_order requires a connected wallet" do
    log_in_as @jordan
    with_aeropay_enabled do
      post tokens_aeropay_order_path, params: { pack: "single", bank_account_id: "bank_1" }, as: :json
    end
    assert_response :unprocessable_entity
    assert_match(/Connect a wallet/, JSON.parse(response.body)["error"])
  end

  test "aeropay_order refuses when the flag is off (deploy-inert gate)" do
    log_in_as_with_wallet @jordan
    with_aeropay_disabled do
      post tokens_aeropay_order_path, params: { pack: "single", bank_account_id: "bank_1" }, as: :json
    end
    assert_response :unprocessable_entity
    assert_match(/isn't enabled/, JSON.parse(response.body)["error"])
    assert_equal 0, AeropayPurchase.count
  end

  test "aeropay_order requires a linked bank account" do
    log_in_as_with_wallet @jordan
    with_aeropay_enabled do
      post tokens_aeropay_order_path, params: { pack: "single" }, as: :json
    end
    assert_response :unprocessable_entity
    assert_match(/Link a bank account/, JSON.parse(response.body)["error"])
    assert_equal 0, AeropayPurchase.count, "a blank bank id must not orphan a pending row"
  end

  test "aeropay_order blocks a payment-risk-flagged user (OPSEC-036)" do
    log_in_as_with_wallet @jordan
    @jordan.update!(payment_risk_flag: true)
    with_aeropay_enabled do
      post tokens_aeropay_order_path, params: { pack: "single", bank_account_id: "bank_1" }, as: :json
    end
    assert_response :forbidden
    assert_equal 0, AeropayPurchase.count
  end

  test "aeropay_order blocks a frozen account (B4 / OPSEC-048)" do
    log_in_as_with_wallet @jordan
    @jordan.freeze_for_payment_risk!(reason: "test freeze")
    with_aeropay_enabled do
      post tokens_aeropay_order_path, params: { pack: "single", bank_account_id: "bank_1" }, as: :json
    end
    assert_response :forbidden
    assert_equal 0, AeropayPurchase.count
  end

  test "aeropay_order creates a pending purchase with SERVER-derived amount and returns the transaction + reference" do
    log_in_as_with_wallet @jordan
    client = FakeAeropayClient.new(transaction_id: "txn_HAPPY", status: "pending")
    with_aeropay_enabled do
      Aeropay::Client.stub :new, client do
        # price_cents is a decoy param — the server must ignore it and use the pack.
        post tokens_aeropay_order_path, params: { pack: "single", bank_account_id: "bank_9", price_cents: 1 }, as: :json
      end
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "txn_HAPPY", body["transaction_id"]
    assert_equal "pending", body["status"]
    assert body["reference"].present?

    purchase = AeropayPurchase.for_reference(body["reference"]).first
    assert_equal @jordan.id, purchase.user_id
    assert_equal "single", purchase.pack_id
    assert_equal 1, purchase.quantity
    assert_equal 19_00, purchase.price_cents, "amount must come from the pack, never the client"
    assert_equal "pending", purchase.status
    assert_equal purchase.slug, purchase.aeropay_reference, "reference IS the slug"
    assert_equal "txn_HAPPY", purchase.aeropay_transaction_id, "the deposit transaction id is persisted before mint"
    assert_equal @jordan.solana_address, purchase.wallet_address
    assert_equal 1, client.deposit_calls.length

    # The deposit is asked for with the exact pack + bank account + reference.
    call = client.deposit_calls.first
    assert_equal 19_00, call[:pack][:price_cents]
    assert_equal "bank_9", call[:bank_account_id]
    assert_equal purchase.aeropay_reference, call[:reference]
  end

  test "aeropay_order records the contest context when given" do
    log_in_as_with_wallet @jordan
    contest = contests(:one)
    with_aeropay_enabled do
      Aeropay::Client.stub :new, FakeAeropayClient.new do
        post tokens_aeropay_order_path, params: { pack: "single", bank_account_id: "bank_1", contest: contest.slug }, as: :json
      end
    end
    assert_response :success
    reference = JSON.parse(response.body)["reference"]
    assert_equal contest.slug, AeropayPurchase.for_reference(reference).first.contest_slug
  end

  test "aeropay_order marks the purchase failed when the Aeropay call raises" do
    log_in_as_with_wallet @jordan
    client = FakeAeropayClient.new
    client.raises = "Aeropay down"
    with_aeropay_enabled do
      Aeropay::Client.stub :new, client do
        post tokens_aeropay_order_path, params: { pack: "single", bank_account_id: "bank_1" }, as: :json
      end
    end
    assert_response :unprocessable_entity
    assert_equal "failed", AeropayPurchase.last.status
  end

  # ── buy page card (flag-gated, additive) ──────────────────────────────────

  test "buy page shows the Aeropay buy-1 card when the flag is on" do
    log_in_as @jordan
    with_aeropay_enabled do
      get tokens_buy_path
    end
    assert_response :success
    assert_select "[data-aeropay-buy]"
    assert_match "Buy 1 entry with Aeropay", response.body
    assert_match "tmAeropayBuyOne('single')", response.body
    assert_match "window.tmAeropayBuyOne", response.body, "the shared kickoff script must render"
  end

  test "buy page hides the Aeropay buy-1 card when the flag is off" do
    log_in_as @jordan
    with_aeropay_disabled { get tokens_buy_path }
    assert_response :success
    # Only the buy-page CARD is flag-gated. The Add Funds hub (a layout-level
    # modal) shows every rail in the test env, so its shared kickoff script is
    # present regardless — assert on the card marker, not the global function.
    assert_select "[data-aeropay-buy]", count: 0
    assert_no_match(/Buy 1 entry with Aeropay/, response.body)
  end

  # ── routing: format suffix must not sidestep the rack-attack throttle ──────

  test "aeropay endpoints reject a format suffix (throttles match exact paths)" do
    assert_equal "aeropay_order",
                 Rails.application.routes.recognize_path("/tokens/aeropay_order", method: :post)[:action]
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/tokens/aeropay_order.json", method: :post)
    end
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/webhooks/aeropay.json", method: :post)
    end
  end

  # ── status (aeropay_reference branch) ─────────────────────────────────────

  test "status resolves an Aeropay purchase by aeropay_reference" do
    purchase = create_pending_purchase(user: @jordan, reference: "aeropay_status")
    purchase.update!(status: "minted", mint_tx_signatures: ["sig_0"].to_json)
    log_in_as @jordan
    get tokens_status_path, params: { aeropay_reference: "aeropay_status" }
    json = JSON.parse(response.body)
    assert json["ready"]
    assert_equal 1, json["minted"]
  end

  test "status scopes aeropay_reference to current_user" do
    purchase = create_pending_purchase(user: @alex, reference: "aeropay_xuser")
    purchase.update!(status: "minted", mint_tx_signatures: ["sig"].to_json)
    log_in_as @jordan
    get tokens_status_path, params: { aeropay_reference: "aeropay_xuser" }
    refute JSON.parse(response.body)["ready"]
  end

  private

  def log_in_as_with_wallet(user)
    user.update!(web2_solana_address: "TestWalletAddr#{SecureRandom.hex(3)}", encrypted_web2_solana_private_key: "x")
    log_in_as user
  end

  def create_pending_purchase(user:, reference:, pack_id: "single", quantity: 1, price_cents: 19_00)
    AeropayPurchase.create!(
      user: user,
      aeropay_reference: reference,
      pack_id: pack_id,
      quantity: quantity,
      price_cents: price_cents,
      wallet_address: "TestWalletAddr#{SecureRandom.hex(3)}",
      status: "pending"
    )
  end

  def with_aeropay_enabled
    original = ENV["ENABLE_AEROPAY"]
    ENV["ENABLE_AEROPAY"] = "true"
    yield
  ensure
    original.nil? ? ENV.delete("ENABLE_AEROPAY") : ENV["ENABLE_AEROPAY"] = original
  end

  # Force the flag OFF regardless of a developer's local .env (which may set
  # ENABLE_AEROPAY=true to run the rail on the dev stack). The "deploy-inert"
  # tests must assert the off state deterministically, not rely on the ambient
  # env being unset.
  def with_aeropay_disabled
    original = ENV["ENABLE_AEROPAY"]
    ENV["ENABLE_AEROPAY"] = "false"
    yield
  ensure
    original.nil? ? ENV.delete("ENABLE_AEROPAY") : ENV["ENABLE_AEROPAY"] = original
  end
end
