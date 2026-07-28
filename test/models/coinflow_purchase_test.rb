require "test_helper"

class CoinflowPurchaseTest < ActiveSupport::TestCase
  setup do
    @user = users(:jordan)
  end

  test "valid statuses include captured; invalid rejected" do
    purchase = build_purchase
    CoinflowPurchase::STATUSES.each do |status|
      purchase.status = status
      assert purchase.valid?, "#{status} should be valid"
    end
    purchase.status = "bogus"
    refute purchase.valid?
  end

  test "coinflow_reference is unique but nullable (row exists before it is set)" do
    a = build_purchase(coinflow_reference: nil)
    b = build_purchase(coinflow_reference: nil)
    assert a.save
    assert b.save, "two rows with nil reference must coexist"

    a.update!(coinflow_reference: "coinflow_uniq")
    b.coinflow_reference = "coinflow_uniq"
    refute b.valid?
  end

  test "coinflow_payment_id is unique but nullable (the webhook dedup key)" do
    a = build_purchase
    b = build_purchase
    assert a.save
    assert b.save

    a.update!(coinflow_payment_id: "pay_uniq")
    b.coinflow_payment_id = "pay_uniq"
    refute b.valid?
  end

  test "amounts derive from StripePurchase::PACKS — single source of truth (cents-native)" do
    pack = StripePurchase.pack("single")
    purchase = build_purchase(pack_id: "single", quantity: pack[:quantity], price_cents: pack[:price_cents])
    assert_equal 19_00, purchase.expected_amount_cents
  end

  test "begin_fulfillment! wins exactly once (atomic pending → captured CAS) and stamps the payment id" do
    purchase = build_purchase
    purchase.save!

    assert purchase.begin_fulfillment!(capture_id: "PAY_1"), "first caller wins"
    assert_equal "captured", purchase.status
    assert_equal "PAY_1", purchase.coinflow_payment_id
    assert purchase.captured_at.present?

    refute purchase.begin_fulfillment!(capture_id: "PAY_2"), "second caller loses"
    assert_equal "PAY_1", purchase.reload.coinflow_payment_id, "loser must not overwrite the payment id"
  end

  test "capture_matches? requires USD + exact pack subtotal cents (never the fee-inclusive total)" do
    purchase = build_purchase(pack_id: "single", quantity: 1, price_cents: 19_00)

    good = { "subtotal" => { "cents" => 1900, "currency" => "USD" }, "total" => { "cents" => 2100, "currency" => "USD" } }
    assert purchase.capture_matches?(good), "subtotal 1900 matches even though total (with fees) is 2100"

    refute purchase.capture_matches?(nil)
    refute purchase.capture_matches?({ "subtotal" => { "cents" => 1900, "currency" => "EUR" } })
    refute purchase.capture_matches?({ "subtotal" => { "cents" => 500, "currency" => "USD" } })
    refute purchase.capture_matches?({ "total" => { "cents" => 1900, "currency" => "USD" } }), "must read subtotal, not total"
  end

  test "capture_matches? fails closed (no raise) on a malformed non-hash subtotal" do
    purchase = build_purchase(pack_id: "single", quantity: 1, price_cents: 19_00)

    # Coinflow documents subtotal as a {cents:, currency:} hash. A bare integer
    # (or any non-hash) is malformed — `.dig` would raise TypeError → webhook 500.
    # The guard must fail closed (false, no mint), never raise.
    result = nil
    assert_nothing_raised do
      result = purchase.capture_matches?({ "subtotal" => 1900 })
    end
    refute result, "a bare-integer subtotal must return false, not match"

    refute purchase.capture_matches?({ "subtotal" => "1900" }), "string subtotal fails closed"
    refute purchase.capture_matches?({ "subtotal" => nil }), "nil subtotal fails closed"

    # Happy path stays intact alongside the guard.
    assert purchase.capture_matches?({ "subtotal" => { "cents" => 1900, "currency" => "USD" } }),
           "well-formed subtotal hash still matches"
  end

  test "slug is immutable after create — it IS the coinflow_reference resolved on settlement" do
    purchase = build_purchase(coinflow_reference: nil)
    purchase.save!
    create_time_slug = purchase.slug
    assert create_time_slug.present?
    assert_match(/\Acoinflow_/, create_time_slug)

    # The production sequence: create → set reference = slug in the same request
    # → later saves (capture / mint). Sluggable's per-save re-derive must NOT
    # regenerate the (pure-entropy) slug, or the reference the webhook resolves
    # on would orphan.
    purchase.update!(coinflow_reference: create_time_slug)
    assert_equal create_time_slug, purchase.reload.slug

    purchase.begin_fulfillment!(capture_id: "PAY_S")
    purchase.mark_minted!(["sig_0"])
    assert_equal create_time_slug, purchase.reload.slug

    assert_equal purchase, CoinflowPurchase.for_reference(create_time_slug).first
  end

  test "mark_minted! never overwrites the refunded terminal (refund-during-mint race)" do
    purchase = build_purchase
    purchase.save!
    purchase.begin_fulfillment!(capture_id: "PAY_RM")
    purchase.mark_refunded!(reason: "mid-mint refund")

    purchase.mark_minted!(%w[sig_a])
    purchase.reload
    assert_equal "refunded", purchase.status
    assert_equal %w[sig_a], purchase.tx_signatures
    assert purchase.minted_at.present?
    assert purchase.refunded_at.present?
  end

  test "MintablePurchase parity: mark_minted!, tx_signatures, H8 no-downgrade" do
    purchase = build_purchase
    purchase.save!

    purchase.mark_minted!(%w[sig_a sig_b])
    assert_equal "minted", purchase.status
    assert_equal %w[sig_a sig_b], purchase.tx_signatures
    assert purchase.minted_at.present?

    purchase.mark_failed_unless_minted!
    assert_equal "minted", purchase.reload.status, "H8: never downgrade a minted purchase"
  end

  # ── pending_for_settlement (tier-3 resolution, the ONLY real webhook path) ──
  #
  # The regression this guards: while the Coinflow rail sold nothing but the $19
  # single, "oldest pending row" was fungible. Offering single AND trio makes
  # heterogeneous-price pending rows reachable, and an amount-blind pick lets an
  # abandoned $19 row absorb a $49 trio settlement — capture_matches? then fails
  # on the amount and the buyer is charged $49 for tokens that never mint.
  # Assert the ROW CHOSEN, not a proxy: a count or a bare non-nil would pass
  # against exactly the wrong row.

  test "picks the buyer's oldest pending row AT THE SETTLED PRICE, not the oldest overall" do
    stale_single = build_purchase(price_cents: 19_00, pack_id: "single", quantity: 1)
    stale_single.created_at = 2.hours.ago
    stale_single.save!
    trio = build_purchase(price_cents: 49_00, pack_id: "trio", quantity: 3)
    trio.created_at = 1.minute.ago
    trio.save!

    found = CoinflowPurchase.pending_for_settlement(user_id: @user.id, cents: 49_00)
    assert_equal trio.id, found.id,
                 "a $49 settlement must bind the trio row, never the older $19 single"
  end

  test "still consumes oldest-first among rows of the SAME price" do
    older = build_purchase(price_cents: 19_00)
    older.created_at = 2.hours.ago
    older.save!
    newer = build_purchase(price_cents: 19_00)
    newer.created_at = 1.minute.ago
    newer.save!

    found = CoinflowPurchase.pending_for_settlement(user_id: @user.id, cents: 19_00)
    assert_equal older.id, found.id,
                 "fungible within a price class — N settlements must drain N rows"
  end

  test "returns nil when no pending row matches the settled amount" do
    build_purchase(price_cents: 19_00).save!
    assert_nil CoinflowPurchase.pending_for_settlement(user_id: @user.id, cents: 49_00)
  end

  # Fail closed: with no trustworthy amount there is no safe row to pick, and
  # guessing is the whole bug.
  test "returns nil on an unreadable settled amount rather than guessing a row" do
    build_purchase(price_cents: 19_00).save!
    [nil, 0, "", "abc"].each do |bad|
      assert_nil CoinflowPurchase.pending_for_settlement(user_id: @user.id, cents: bad),
                 "cents=#{bad.inspect} must not resolve to any row"
    end
  end

  test "never reaches another buyer's pending row" do
    other = users(:sam)
    mine = build_purchase(price_cents: 19_00)
    mine.created_at = 1.minute.ago
    mine.save!
    theirs = CoinflowPurchase.new(user: other, pack_id: "single", quantity: 1,
                                  price_cents: 19_00, status: "pending")
    theirs.created_at = 2.hours.ago
    theirs.save!

    found = CoinflowPurchase.pending_for_settlement(user_id: @user.id, cents: 19_00)
    assert_equal mine.id, found.id
  end

  test "ignores rows that are no longer pending" do
    captured = build_purchase(price_cents: 19_00, status: "captured")
    captured.save!
    assert_nil CoinflowPurchase.pending_for_settlement(user_id: @user.id, cents: 19_00)
  end

  private

  def build_purchase(**overrides)
    CoinflowPurchase.new({
      user: @user,
      pack_id: "single",
      quantity: 1,
      price_cents: 19_00,
      status: "pending"
    }.merge(overrides))
  end
end
