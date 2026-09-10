# frozen_string_literal: true

require "test_helper"

# A SIGNED CREATE TOKEN MINTED BEFORE THIS DEPLOY MUST STILL PERSIST.
#
# ContestsController#create mints an HMAC-signed payload, the operator's Phantom
# wallet signs the create_contest transaction, and #finalize rebuilds the
# Contest from THAT PAYLOAD — not from params. A field added to the payload is
# therefore ABSENT from every token already in flight when the deploy lands.
#
# WHY IT STILL MATTERS, now that it is no longer a money bug. `coming_soon` is
# NOT NULL, and an explicitly-assigned nil is sent in the INSERT rather than
# falling back to the column default, so a legacy payload raises
# PG::NotNullViolation on save.
#
# WHEN this file was written, that save ran AFTER
# `cosign_and_broadcast_create_contest` — the creator's prize pool had already
# left their wallet for the vault, so the raise stranded a funded on-chain
# Contest PDA with no database row. Nothing swept it up
# (Solana::Reconciler#reconcile_contest takes a Contest record, so a rowless
# orphan is invisible to it), and retrying was not a repair: the slug guard
# asked the DATABASE, the missing row was exactly what it looked for, so the
# retry sailed past it and died on chain against the already-initialized PDA.
#
# THAT ORDERING IS FIXED (task harden-finalize-write-ordering, 2026-09-05).
# #finalize now saves the row — status `pending`, carrying the derived PDA —
# BEFORE the broadcast, so a legacy payload now fails cleanly with no money in
# flight. The fallback is still load-bearing: without it the operator gets a
# 500 instead of a contest, which is a bug worth a test even when it is no
# longer a bug worth money. The ordering itself is pinned separately by
# test/controllers/contests_finalize_write_ordering_test.rb.
#
# Found in review of PR #544 by Carl (primary) and Jasper (light), independently.
class ContestsLegacyCreateTokenTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:alex)
    @slate = slates(:one)
  end

  # The payload as #create minted it BEFORE coming_soon existed: every other key
  # present, that one simply absent. `with_indifferent_access` mirrors what
  # #verify_onchain_create_payload actually hands #finalize.
  def legacy_payload(extra = {})
    {
      slug: "legacy-token-contest",
      name: "Legacy Token Contest",
      slate_id: @slate.id,
      contest_type: "standard",
      starts_at: 30.days.from_now.iso8601,
      locks_at_date_selected: nil,
      locks_at_time_selected: nil,
      locks_at_timezone_selected: nil,
      entry_fee_cents: 1900,
      max_entries: 29,
      season_id: 0,
      user_id: @user.id,
      creator_pubkey: "FakePubkey11111111111111111111111111111111"
    }.merge(extra).with_indifferent_access
  end

  # `build_pending_contest` is the renamed `build_finalized_contest`: since the
  # write-ahead reordering the builder produces the row saved BEFORE the
  # broadcast, so it takes no signature. It is still the only builder whose
  # contest is persisted, which is why this file targets it.
  def build_from(payload)
    controller = ContestsController.new
    user = @user
    controller.define_singleton_method(:current_user) { user }
    controller.send(:build_pending_contest, payload, "FakePda1111111111111111111111111111111111")
  end

  test "a payload with no coming_soon key still saves" do
    contest = build_from(legacy_payload)

    # save!, not valid? — the defect is a database NOT NULL violation, and an
    # ActiveModel validation pass says nothing about it.
    assert_nothing_raised { contest.save! }
    assert_equal false, contest.reload.coming_soon,
      "a legacy token must land as not-coming-soon, never as nil"
  end

  # The control. Without it the fix could hardcode false and this file would
  # still be green while the operator's checkbox silently stopped working.
  test "a payload that does carry coming_soon keeps the operator's choice" do
    contest = build_from(legacy_payload(coming_soon: true))
    contest.save!

    assert_equal true, contest.reload.coming_soon
  end

  test "an explicit false is preserved and not confused with an absent key" do
    contest = build_from(legacy_payload(coming_soon: false))
    contest.save!

    assert_equal false, contest.reload.coming_soon
  end
end
