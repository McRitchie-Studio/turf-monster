require "test_helper"

# turf-vault's `update_signers` guards, mirrored in Ruby — and this file's job
# is to prove the mirror still matches the program, ORDER INCLUDED.
#
# ── WHY ORDER IS ASSERTED AND NOT JUST THE VERDICT ───────────────────────────
#
# Anchor returns the FIRST failing constraint and stops. A set that breaks two
# rules surfaces only the earlier one on chain, so a Rails validator that
# refused in a different order would hand the operator a sentence naming a
# DIFFERENT problem than the one the chain would name — mid-incident, on the one
# control he has. Every refusal here therefore asserts the program's error CODE,
# and the multi-fault cases assert which of two codes wins.
#
# Source of truth, read at turf-vault `accepted` on 2026-09-15:
#   programs/turf_vault/src/instructions/update_signers.rs (v0.26)
#   the same file at tag v0.25.0                            (what is DEPLOYED)
class Solana::SignerRotationTest < ActiveSupport::TestCase
  # Five distinct, valid-length base58 keys. Real pubkeys from the measured
  # sets so a decode helper cannot quietly reject them.
  SYSTEM  = "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd".freeze
  ALEX    = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr".freeze
  MASON   = "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR".freeze
  ALEX2   = "3Qj4v9qjhXgkru6zCRCErRVhy8Q6qU3NrNpvpXLTZboA".freeze
  ALEX3   = "9gACbzsCLmkYF9Yx1EBGmwMvvyfuTquJ6qs8QsoQvHXf".freeze
  EMPTY   = Solana::SignerRotation::EMPTY

  def rotation(proposed:, authorizers:, current: [SYSTEM, ALEX, MASON],
               governance: true, max_live: 3)
    Solana::SignerRotation.for_chain(
      current_signers: current,
      proposed: proposed,
      authorizers: authorizers,
      governance: governance,
      max_live_threshold: max_live
    )
  end

  def refusal_for(...)
    rotation(...).validate!
    nil
  rescue Solana::SignerRotation::Refusal => e
    e
  end

  # ── THE HAPPY PATH THIS WHOLE PAGE EXISTS FOR ─────────────────────────────

  test "v0.26 accepts a REDUCED set that evicts a non-authorizing key" do
    # Five live, evicting two, down to three — the brief's exact end state.
    plan = rotation(
      current: [SYSTEM, ALEX, MASON, ALEX2, ALEX3],
      proposed: [ALEX, ALEX2, ALEX3],
      authorizers: [ALEX, ALEX2, ALEX3]
    )

    assert plan.valid?, plan.refusal_message
    assert_equal [SYSTEM, MASON], plan.evicted
    assert_equal [ALEX, ALEX2, ALEX3], plan.retained
    assert_equal [], plan.added
    # Trailing slots go empty, and they are EXPLICIT zero pubkeys — Anchor
    # encodes a fixed-length array with no length prefix, so an omitted tail
    # would shift nothing and deserialize short.
    assert_equal [ALEX, ALEX2, ALEX3, EMPTY, EMPTY], plan.padded_slots
  end

  test "a widening rotation that evicts nobody is accepted" do
    plan = rotation(proposed: [SYSTEM, ALEX, MASON, ALEX2, ALEX3],
                    authorizers: [SYSTEM, ALEX, MASON])
    assert plan.valid?, plan.refusal_message
    assert_equal [], plan.evicted
    assert_equal [ALEX2, ALEX3], plan.added
  end

  # ── REFUSALS. The point of the feature, not the edge of it. ───────────────

  test "a set below the update_signers threshold is refused as SignerSetTooSmall" do
    e = refusal_for(current: [SYSTEM, ALEX, MASON, ALEX2, ALEX3],
                    proposed: [ALEX, ALEX2],
                    authorizers: [ALEX, ALEX2, ALEX3])

    assert_not_nil e, "a 2-key set must be refused against a threshold of 3"
    assert_equal 6052, e.code
    assert_equal "SignerSetTooSmall", e.error_name
    assert_match(/cannot satisfy update_signers' own threshold of 3/, e.message)
  end

  test "a set that satisfies update_signers but not the highest live action is refused" do
    # update_signers needs 3 and so does settle_contest; this proves the SECOND
    # count rule is live independently — a set of exactly `required` still has
    # to clear `max_live`.
    e = refusal_for(current: [SYSTEM, ALEX, MASON, ALEX2, ALEX3],
                    proposed: [ALEX, ALEX2, ALEX3],
                    authorizers: [ALEX, ALEX2, ALEX3],
                    max_live: 4)

    assert_not_nil e
    assert_equal 6052, e.code
    assert_match(/highest on-chain threshold is 4/, e.message)
  end

  test "a gap before an occupied slot is refused, even though the keys are fine" do
    # [ALEX, "", ALEX2, ALEX3] — four healthy keys, one hole. `all_signers()`
    # would happily skip it, which is exactly why the program refuses it: the
    # count would depend on who is reading.
    e = refusal_for(current: [SYSTEM, ALEX, MASON, ALEX2, ALEX3],
                    proposed: [ALEX, "", ALEX2, ALEX3],
                    authorizers: [ALEX, ALEX2, ALEX3])

    assert_not_nil e, "a gap must be refused"
    assert_equal 6052, e.code
    assert_match(/slot 3 holds a key while an earlier slot is empty/, e.message)
  end

  test "the empty sentinel counts as a gap, not as a key" do
    e = refusal_for(current: [SYSTEM, ALEX, MASON, ALEX2, ALEX3],
                    proposed: [ALEX, EMPTY, ALEX2, ALEX3],
                    authorizers: [ALEX, ALEX2, ALEX3])

    assert_not_nil e
    assert_equal 6052, e.code
  end

  test "a duplicated key is refused as DuplicateSigner" do
    e = refusal_for(current: [SYSTEM, ALEX, MASON, ALEX2, ALEX3],
                    proposed: [ALEX, ALEX, ALEX2],
                    authorizers: [ALEX, ALEX2, ALEX3])

    assert_not_nil e
    assert_equal 6014, e.code
    assert_match(/appears more than once/, e.message)
  end

  test "a rotation that does not retain its own authorizers is refused" do
    # The defining refusal: ALEX3 signs and is then dropped. With required == 3
    # and exactly three authorizers, ALL of them must survive.
    e = refusal_for(current: [SYSTEM, ALEX, MASON, ALEX2, ALEX3],
                    proposed: [ALEX, ALEX2, MASON],
                    authorizers: [ALEX, ALEX2, ALEX3])

    assert_not_nil e
    assert_equal 6017, e.code
    assert_equal "SignerContinuityRequired", e.error_name
    assert_match(/#{ALEX3}/, e.message)
    assert_match(/sign the transaction and then be evicted by it/, e.message)
  end

  test "a key that did NOT authorize may be dropped freely" do
    # The other half of continuity, and the half that makes eviction possible
    # at all. Without this assertion the rule above could be over-implemented
    # into "nothing may ever be evicted" and the suite would not notice.
    plan = rotation(current: [SYSTEM, ALEX, MASON, ALEX2, ALEX3],
                    proposed: [ALEX, ALEX2, ALEX3],
                    authorizers: [ALEX, ALEX2, ALEX3])
    assert plan.valid?
    assert_includes plan.evicted, SYSTEM
  end

  test "an authorizer outside the on-chain set is refused as Unauthorized" do
    e = refusal_for(proposed: [SYSTEM, ALEX, MASON],
                    authorizers: [ALEX, ALEX2, ALEX3])

    assert_not_nil e
    assert_equal 6000, e.code
    assert_match(/is not in the vault's on-chain signer set/, e.message)
  end

  test "too few authorizers is refused as InsufficientSigners" do
    e = refusal_for(current: [SYSTEM, ALEX, MASON, ALEX2, ALEX3],
                    proposed: [ALEX, ALEX2, ALEX3],
                    authorizers: [ALEX, ALEX2])

    assert_not_nil e
    assert_equal 6046, e.code
    assert_match(/needs 3 vault signatures and 2 were named/, e.message)
  end

  test "a repeated authorizer is refused as DuplicateSigner, not counted twice" do
    e = refusal_for(current: [SYSTEM, ALEX, MASON, ALEX2, ALEX3],
                    proposed: [ALEX, ALEX2, ALEX3],
                    authorizers: [ALEX, ALEX, ALEX2])

    assert_not_nil e
    assert_equal 6014, e.code
    assert_match(/would authorize this rotation more than once/, e.message)
  end

  # ── ORDER. Which refusal wins when a set breaks two rules. ────────────────

  test "authorization is judged before the shape of the proposed set" do
    # Unknown authorizer AND a 1-key set. The chain runs `authorize` first, so
    # Unauthorized wins — telling the operator to fix the SIGNERS, not the set.
    e = refusal_for(proposed: [ALEX],
                    authorizers: [ALEX2, ALEX3, ALEX])

    assert_equal 6000, e.code, "authorize runs before any shape check"
  end

  test "a gap is reported before a duplicate" do
    # [ALEX, "", ALEX, ALEX2] breaks both. The handler's gap loop runs first.
    e = refusal_for(current: [SYSTEM, ALEX, MASON, ALEX2, ALEX3],
                    proposed: [ALEX, "", ALEX, ALEX2],
                    authorizers: [ALEX, ALEX2, ALEX3])

    assert_equal 6052, e.code, "the gap loop precedes the duplicate loop"
    assert_match(/earlier slot is empty/, e.message)
  end

  test "a duplicate is reported before the count rules" do
    # [ALEX, ALEX] is both duplicated and too small. Duplicates come first.
    e = refusal_for(current: [SYSTEM, ALEX, MASON, ALEX2, ALEX3],
                    proposed: [ALEX, ALEX],
                    authorizers: [ALEX, ALEX2, ALEX3])

    assert_equal 6014, e.code, "the duplicate loop precedes count >= required"
  end

  test "continuity is judged LAST, after the set's shape is known good" do
    # Too small AND breaks continuity. Size wins, matching the handler.
    e = refusal_for(current: [SYSTEM, ALEX, MASON, ALEX2, ALEX3],
                    proposed: [MASON, SYSTEM],
                    authorizers: [ALEX, ALEX2, ALEX3])

    assert_equal 6052, e.code, "the count rules precede the continuity check"
  end

  # ── THE DEPLOYED v0.25 SHAPE ─────────────────────────────────────────────
  #
  # Not a legacy branch: this is what devnet and mainnet actually run today.
  # GovernanceConfig is ABSENT on both (measured 2026-09-15), so the live
  # program takes three slots, exactly two signatures, and refuses any zeroed
  # slot outright.

  test "v0.25 refuses a reduced set because the deployed program forbids empty slots" do
    e = refusal_for(proposed: [ALEX, MASON],
                    authorizers: [ALEX, MASON],
                    governance: false, max_live: nil)

    assert_not_nil e, "the deployed program cannot express a 2-key set"
    assert_equal 6017, e.code
    assert_match(/takes exactly 3 signers and refuses a zeroed slot/, e.message)
    assert_match(/needs turf-vault v0\.26 on chain first/, e.message)
  end

  test "v0.25 evicts by REPLACEMENT — the only shape it has" do
    # Today's live set is [SYSTEM, ALEX, MASON]. Evicting SYSTEM means ALEX and
    # MASON sign and a third key takes the empty seat.
    plan = rotation(proposed: [ALEX, MASON, ALEX2],
                    authorizers: [ALEX, MASON],
                    governance: false, max_live: nil)

    assert plan.valid?, plan.refusal_message
    assert_equal 2, plan.required
    assert_equal 3, plan.max_slots
    assert_equal [SYSTEM], plan.evicted
    assert_equal [ALEX2], plan.added
    assert_equal [ALEX, MASON, ALEX2], plan.padded_slots
  end

  test "v0.25 continuity still refuses dropping an authorizer" do
    e = refusal_for(proposed: [ALEX, ALEX2, ALEX3],
                    authorizers: [ALEX, MASON],
                    governance: false, max_live: nil)

    assert_not_nil e
    assert_equal 6017, e.code
    assert_match(/#{MASON}/, e.message)
  end

  test "v0.25 needs exactly two signatures, not three" do
    e = refusal_for(proposed: [ALEX, MASON, ALEX2],
                    authorizers: [ALEX],
                    governance: false, max_live: nil)

    assert_equal 6046, e.code
    assert_match(/needs 2 vault signatures/, e.message)
  end

  # ── THE PLAN THE PAGE AND THE RECORD BOTH READ ───────────────────────────

  test "to_plan reports the shape, the slot width and the diff" do
    plan = rotation(current: [SYSTEM, ALEX, MASON, ALEX2, ALEX3],
                    proposed: [ALEX, ALEX2, ALEX3],
                    authorizers: [ALEX, ALEX2, ALEX3]).to_plan

    assert_equal "v0.26", plan[:shape]
    assert_equal 3, plan[:required_signatures]
    assert_equal 5, plan[:max_slots]
    assert_equal [SYSTEM, MASON], plan[:evicted]
    assert_equal [ALEX, ALEX2, ALEX3, EMPTY, EMPTY], plan[:padded]
  end

  test "refusal_message returns the sentence without the caller rescuing" do
    plan = rotation(current: [SYSTEM, ALEX, MASON, ALEX2, ALEX3],
                    proposed: [ALEX, ALEX2],
                    authorizers: [ALEX, ALEX2, ALEX3])

    assert_not plan.valid?
    assert_match(/SignerSetTooSmall, 6052/, plan.refusal_message)
  end

  test "every refusal names the program error code and name" do
    # A blanket assertion, because the VALUE of this class is that its sentences
    # use the chain's vocabulary. A refusal that said "invalid set" would be
    # worse than no refusal — it would send the operator looking in Rails.
    e = refusal_for(current: [SYSTEM, ALEX, MASON, ALEX2, ALEX3],
                    proposed: [ALEX, ALEX2],
                    authorizers: [ALEX, ALEX2, ALEX3])

    assert_match(/turf-vault would reject this as \w+, \d{4}\./, e.message)
  end
end
