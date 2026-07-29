require "test_helper"
require "minitest/mock"

class StripePurchaseTest < ActiveSupport::TestCase
  # PACKS prices must stay DISTINCT — a load-bearing invariant nothing else
  # enforces. CoinflowPurchase.pending_for_settlement resolves a Coinflow
  # settlement by (user, pending, price_cents), because Coinflow's `Settled`
  # payload carries no reference and the amount is the only discriminator we
  # get. Two packs sharing a price makes that resolution ambiguous, and the
  # failure is SILENT: the resolver picks whichever row is older,
  # capture_matches? compares the same price_cents and passes, and the buyer is
  # minted the WRONG QUANTITY with every check green.
  #
  # This is a live risk, not a hypothetical: PACKS is deliberately keyed by
  # string id rather than quantity precisely so two packs can share a quantity
  # (trio and test_trio both sell 3), so the constant's own shape invites a
  # near-collision. A repricing is all it would take.
  #
  # If you are here because this test failed: DO NOT just make the prices
  # unique again and move on — first check whether pending_for_settlement still
  # resolves unambiguously, because a same-price pair breaks it by construction.
  test "every pack has a DISTINCT price — Coinflow settlement resolution depends on it" do
    prices = StripePurchase::PACKS.values.map { |pack| pack[:price_cents] }
    duplicates = prices.tally.select { |_cents, count| count > 1 }.keys

    assert_empty duplicates,
                 "packs share a price (#{duplicates.inspect} cents) — " \
                 "CoinflowPurchase.pending_for_settlement resolves by price and " \
                 "would mint the wrong quantity for one of them"
    assert_equal StripePurchase::PACKS.length, prices.uniq.length
  end

  test "PACKS resolves price + quantity by string id" do
    assert_equal 19_00, StripePurchase.pack_price_cents("single")
    assert_equal 1,     StripePurchase.pack_quantity("single")
    assert_equal 49_00, StripePurchase.pack_price_cents("trio")
    assert_equal 3,     StripePurchase.pack_quantity("trio")
  end

  test "test_trio is the $5 / 3-token scaffolding bundle" do
    assert_equal 5_00, StripePurchase.pack_price_cents("test_trio")
    assert_equal 3,    StripePurchase.pack_quantity("test_trio")
  end

  test "per_token_cents divides pack price by quantity" do
    assert_equal 19_00, StripePurchase.per_token_cents("single")
    assert_equal 1633,  StripePurchase.per_token_cents("trio")       # 4900 / 3
    assert_equal 166,   StripePurchase.per_token_cents("test_trio")  # 500 / 3
  end

  test "pack raises KeyError for an unknown id" do
    assert_raises(KeyError) { StripePurchase.pack("nope") }
  end

  test "mark_failed_unless_minted! preserves minted status (H8)" do
    # Simulates the rescue path firing AFTER mark_minted! has already run —
    # e.g. TransactionLog.record! raising on a DB hiccup post-mint. The audit
    # row must stay "minted" to match on-chain reality.
    user = users(:sam)
    purchase = StripePurchase.create!(
      user: user,
      stripe_session_id: "sid-h8-keep",
      quantity: 1,
      price_cents: 1900,
      status: "minted"
    )

    purchase.mark_failed_unless_minted!

    assert_equal "minted", purchase.reload.status
  end

  test "mark_failed_unless_minted! marks pending purchases as failed" do
    user = users(:sam)
    purchase = StripePurchase.create!(
      user: user,
      stripe_session_id: "sid-h8-fail",
      quantity: 1,
      price_cents: 1900,
      status: "pending"
    )

    purchase.mark_failed_unless_minted!

    assert_equal "failed", purchase.reload.status
  end

  test "mark_failed_unless_minted! reads the current DB row (race safety)" do
    # If a concurrent process / re-delivered webhook minted the purchase
    # while this job was mid-rescue, the rescue MUST see the latest state.
    # The method reloads before checking.
    user = users(:sam)
    purchase = StripePurchase.create!(
      user: user,
      stripe_session_id: "sid-h8-race",
      quantity: 1,
      price_cents: 1900,
      status: "pending"
    )

    # Concurrent path: another process flips the row to minted.
    StripePurchase.where(id: purchase.id).update_all(status: "minted")
    # The in-memory purchase still thinks it's pending.
    assert_equal "pending", purchase.status

    purchase.mark_failed_unless_minted!

    # Reloads, sees minted, refuses to downgrade.
    assert_equal "minted", purchase.reload.status
  end

  test "available_packs hides test_trio unless test scaffolding is on" do
    AppFlags.stub :test_scaffolding?, false do
      assert_not StripePurchase.available_packs.key?("test_trio")
      assert StripePurchase.available_packs.key?("single")
      assert StripePurchase.available_packs.key?("trio")
    end
    AppFlags.stub :test_scaffolding?, true do
      assert StripePurchase.available_packs.key?("test_trio")
    end
  end
end
