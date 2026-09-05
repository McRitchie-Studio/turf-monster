# frozen_string_literal: true

require "test_helper"

# A SIGNED CREATE TOKEN MINTED BEFORE THIS DEPLOY MUST STILL PERSIST.
#
# ContestsController#create mints an HMAC-signed payload, the operator's Phantom
# wallet signs the create_contest transaction, and #finalize rebuilds the
# Contest from THAT PAYLOAD — not from params. A field added to the payload is
# therefore ABSENT from every token already in flight when the deploy lands.
#
# WHY THAT IS WORSE THAN A 500, and why this test is a controller test rather
# than a model one. #finalize's order of operations is:
#
#   contests_controller.rb:298  cosign_and_broadcast_create_contest  <- USDC MOVES
#   contests_controller.rb:311  contest.save!                        <- row written
#
# The creator's prize pool leaves their wallet for the vault BEFORE the row is
# written. `coming_soon` is NOT NULL, and an explicitly-assigned nil is sent in
# the INSERT rather than falling back to the column default, so a legacy payload
# raised PG::NotNullViolation at :311 — AFTER the money. That leaves a funded
# on-chain Contest PDA with no database row, and nothing sweeps it up:
# Solana::Reconciler#reconcile_contest takes a Contest record, so a rowless
# orphan is invisible to it. Retrying is not a repair either — the slug guard at
# :284 asks the DATABASE, and the missing row is exactly what it looks for, so
# the retry sails past it and then fails on chain against the already-initialized
# PDA; a fresh slug funds a SECOND contest and strands the first one's USDC.
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

  def build_from(payload)
    controller = ContestsController.new
    user = @user
    controller.define_singleton_method(:current_user) { user }
    controller.send(:build_finalized_contest, payload, "FakePda1111111111111111111111111111111111", "FakeSig")
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
