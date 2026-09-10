require "test_helper"

class AeropayPurchaseTest < ActiveSupport::TestCase
  setup do
    @user = users(:jordan)
  end

  test "valid statuses include captured; invalid rejected" do
    purchase = build_purchase
    AeropayPurchase::STATUSES.each do |status|
      purchase.status = status
      assert purchase.valid?, "#{status} should be valid"
    end
    purchase.status = "bogus"
    refute purchase.valid?
  end

  test "aeropay_reference is unique but nullable (row exists before it is set)" do
    a = build_purchase(aeropay_reference: nil)
    b = build_purchase(aeropay_reference: nil)
    assert a.save
    assert b.save, "two rows with nil reference must coexist"

    a.update!(aeropay_reference: "aeropay_uniq")
    b.aeropay_reference = "aeropay_uniq"
    refute b.valid?
  end

  test "aeropay_transaction_id is unique but nullable (the webhook dedup key)" do
    a = build_purchase
    b = build_purchase
    assert a.save
    assert b.save

    a.update!(aeropay_transaction_id: "txn_uniq")
    b.aeropay_transaction_id = "txn_uniq"
    refute b.valid?
  end

  test "amounts derive from StripePurchase::PACKS — single source of truth" do
    pack = StripePurchase.pack("single")
    purchase = build_purchase(pack_id: "single", quantity: pack[:quantity], price_cents: pack[:price_cents])
    assert_equal 19_00, purchase.expected_amount_cents
  end

  test "begin_fulfillment! wins exactly once (atomic pending → captured CAS) and stamps the transaction id" do
    purchase = build_purchase
    purchase.save!

    assert purchase.begin_fulfillment!(capture_id: "TXN_1"), "first caller wins"
    assert_equal "captured", purchase.status
    assert_equal "TXN_1", purchase.aeropay_transaction_id
    assert purchase.captured_at.present?

    refute purchase.begin_fulfillment!(capture_id: "TXN_2"), "second caller loses"
    assert_equal "TXN_1", purchase.reload.aeropay_transaction_id, "loser must not overwrite the transaction id"
  end

  test "capture_matches? requires USD + exact pack amount in decimal dollars" do
    purchase = build_purchase(pack_id: "single", quantity: 1, price_cents: 19_00)

    assert purchase.capture_matches?({ "amount" => "19.00", "currency" => "USD" })
    assert purchase.capture_matches?({ "amount" => 19.0, "currency" => "USD" }), "tolerates a numeric amount"
    assert purchase.capture_matches?({ "amount" => { "value" => "19.00", "currency" => "USD" } }),
           "tolerates a nested amount object"

    refute purchase.capture_matches?(nil)
    refute purchase.capture_matches?({ "amount" => "19.00", "currency" => "EUR" })
    refute purchase.capture_matches?({ "amount" => "0.49", "currency" => "USD" })
    refute purchase.capture_matches?({ "currency" => "USD" }), "a missing amount never matches"
  end

  test "capture_matches? on a scalar amount with no currency degrades to false, never raises" do
    # Regression: `currency` did `payload.dig("amount","currency")` unguarded, so a
    # scalar amount ("19.00" — the assumed Aeropay shape) with NO top-level currency
    # raised TypeError → the webhook 500'd BEFORE the CAS → a paid deposit never
    # minted. It must degrade to nil → no match → the webhook 200-acks.
    purchase = build_purchase(pack_id: "single", quantity: 1, price_cents: 19_00)
    assert_nothing_raised { purchase.capture_matches?({ "amount" => "19.00" }) }
    refute purchase.capture_matches?({ "amount" => "19.00" }), "scalar amount, no currency → no match"
    refute purchase.capture_matches?({ "amount" => 19 }), "scalar integer amount, no currency → no match"
  end

  test "slug is immutable after create — it IS the aeropay_reference resolved on settlement" do
    purchase = build_purchase(aeropay_reference: nil)
    purchase.save!
    create_time_slug = purchase.slug
    assert create_time_slug.present?
    assert_match(/\Aaeropay_/, create_time_slug)

    # Production sequence: create → set reference = slug in the same request →
    # later saves (capture / mint). Sluggable's per-save re-derive must NOT
    # regenerate the (pure-entropy) slug, or the reference the webhook resolves
    # on would orphan.
    purchase.update!(aeropay_reference: create_time_slug)
    assert_equal create_time_slug, purchase.reload.slug

    purchase.begin_fulfillment!(capture_id: "TXN_S")
    purchase.mark_minted!(["sig_0"])
    assert_equal create_time_slug, purchase.reload.slug

    assert_equal purchase, AeropayPurchase.for_reference(create_time_slug).first
  end

  test "for_transaction resolves by the stamped transaction id" do
    purchase = build_purchase(aeropay_transaction_id: "txn_lookup")
    purchase.save!
    assert_equal purchase, AeropayPurchase.for_transaction("txn_lookup").first
  end

  test "mark_minted! never overwrites the refunded terminal (refund-during-mint race)" do
    purchase = build_purchase
    purchase.save!
    purchase.begin_fulfillment!(capture_id: "TXN_RM")
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

  private

  def build_purchase(**overrides)
    AeropayPurchase.new({
      user: @user,
      pack_id: "single",
      quantity: 1,
      price_cents: 19_00,
      status: "pending"
    }.merge(overrides))
  end
end
