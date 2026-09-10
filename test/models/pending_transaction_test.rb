require "test_helper"

# BL4 (Stage 3 audit): PendingTransaction is the row that backs every 2-of-3
# Squads multisig settlement TX. Bug here = ops can't pay winners.
class PendingTransactionTest < ActiveSupport::TestCase
  setup do
    @contest = contests(:one)
  end

  def build_ptx(**overrides)
    PendingTransaction.new({
      tx_type: "settle_contest",
      serialized_tx: "base64-tx-blob-#{SecureRandom.hex(4)}",
      status: "pending",
      target: @contest,
      initiator_address: "InitAddr",
      metadata: { winners: [{ wallet: "WinnerAddr", amount: 30000 }] }
    }.merge(overrides))
  end

  test "tx_type is required" do
    ptx = build_ptx(tx_type: nil)
    refute ptx.valid?
    assert ptx.errors[:tx_type].any?
  end

  test "serialized_tx is required" do
    ptx = build_ptx(serialized_tx: nil)
    refute ptx.valid?
    assert ptx.errors[:serialized_tx].any?
  end

  test "status must be one of the documented values" do
    %w[pending submitted confirmed expired failed].each do |s|
      assert build_ptx(status: s).valid?, "status=#{s.inspect} should be valid"
    end
    refute build_ptx(status: "bogus").valid?
  end

  test "target is polymorphic and can hold a Contest" do
    ptx = build_ptx; ptx.save!
    assert_equal "Contest", ptx.reload.target_type
    assert_equal @contest.id, ptx.target_id
    assert_equal @contest, ptx.target
  end

  test "target is optional — a multisig op without a target row persists" do
    ptx = build_ptx(target: nil, tx_type: "update_signers")
    assert ptx.save
    assert_nil ptx.reload.target
  end

  test "#pending? and #confirmed? mirror status string" do
    assert build_ptx(status: "pending").pending?
    refute build_ptx(status: "pending").confirmed?
    refute build_ptx(status: "confirmed").pending?
    assert build_ptx(status: "confirmed").confirmed?
  end

  test "scope :pending returns only pending rows" do
    pending_ptx = build_ptx(status: "pending"); pending_ptx.save!
    confirmed   = build_ptx(status: "confirmed"); confirmed.save!

    assert_includes PendingTransaction.pending, pending_ptx
    refute_includes PendingTransaction.pending, confirmed
  end

  test "metadata jsonb survives a save/reload round-trip (winners shape)" do
    winners = [
      { "wallet" => "AlphaAddr", "amount" => 30000 },
      { "wallet" => "BetaAddr",  "amount" => 5000  }
    ]
    ptx = build_ptx(metadata: { "winners" => winners, "contest_slug" => @contest.slug })
    ptx.save!; ptx.reload

    assert_equal winners, ptx.metadata["winners"]
    assert_equal @contest.slug, ptx.metadata["contest_slug"]
  end

  test "#parsed_metadata returns {} when metadata column is blank" do
    ptx = build_ptx; ptx.save!
    ptx.update_column(:metadata, nil)
    assert_equal({}, ptx.reload.parsed_metadata)
  end

  # BL4 regression test for the slug bug fix.
  # Pre-fix every row got slug "ptx-" and the unique index meant only ONE
  # PendingTransaction could exist at a time (treasury blocker).
  test "after_create assigns slug 'ptx-<id>' — multiple rows coexist" do
    ptx1 = build_ptx; ptx1.save!
    ptx2 = build_ptx; ptx2.save!

    assert_match(/\Aptx-\d+\z/, ptx1.slug)
    assert_match(/\Aptx-\d+\z/, ptx2.slug)
    assert_not_equal ptx1.slug, ptx2.slug
  end

  test "to_param returns the slug (per Sluggable)" do
    ptx = build_ptx; ptx.save!
    assert_equal ptx.slug, ptx.to_param
  end

  # Single-use broadcast signatures (Lazarus audit #8 residual). A finalized
  # tx_signature may back at most one PendingTransaction; unbroadcast (nil) rows
  # are unconstrained. Mirrors the entries.onchain_tx_signature guard.
  test "tx_signature is unique among non-null rows; nil is unconstrained" do
    sig = "Sig#{SecureRandom.hex(8)}"
    build_ptx(tx_signature: sig).save!

    dup = build_ptx(tx_signature: sig)
    refute dup.valid?, "a second row with the same tx_signature must be rejected"
    assert dup.errors[:tx_signature].any?

    assert build_ptx(tx_signature: nil).save, "first nil-signature row saves"
    assert build_ptx(tx_signature: nil).save, "second nil-signature row coexists"
  end

  # --- awaiting_signature: what the Signatures badge counts ---

  def ptx(status: "pending", stale: false)
    PendingTransaction.create!(
      tx_type: "settle_contest", serialized_tx: "WIRE-#{SecureRandom.hex(4)}",
      status: status, stale: stale, initiator_address: "init", metadata: {}.to_json
    )
  end

  test "awaiting_signature counts a pending row that is not stale" do
    t = ptx
    assert_includes PendingTransaction.awaiting_signature, t
  end

  # The whole reason the column exists. Production held 11 pending rows and 10
  # were dead enter_contest transactions from June and July — a badge counting
  # plain `pending` would have read 11 on the day it shipped.
  test "awaiting_signature excludes a pending row marked stale" do
    t = ptx(stale: true)
    assert_not_includes PendingTransaction.awaiting_signature, t
    assert_includes PendingTransaction.pending, t, "stale must not change what `pending` means"
  end

  test "awaiting_signature excludes rows that are not pending" do
    %w[submitted confirmed expired failed].each do |status|
      t = ptx(status: status)
      assert_not_includes PendingTransaction.awaiting_signature, t, "#{status} should not await a signature"
    end
  end

  test "stale defaults to false so existing rows keep counting" do
    assert_equal false, ptx.reload.stale
  end

  test "awaiting_signature is a subset of pending" do
    ptx
    ptx(stale: true)
    ptx(status: "confirmed")
    assert_operator PendingTransaction.awaiting_signature.count, :<=, PendingTransaction.pending.count
  end
end
