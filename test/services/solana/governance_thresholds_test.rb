require "test_helper"

# The Ruby mirror of turf-vault's per-action threshold table.
#
# WHAT THIS FILE IS DEFENDING. Rails has to decide how many signer slots to
# leave EMPTY in `remaining_accounts` before any signature exists, and it
# decides that from `Solana::Governance`. If this table says two where the
# program says three, the transaction is built one slot short and the chain
# refuses it — which is precisely the defect this whole change exists to close.
# So these are not tests of arithmetic; they are tests that two repositories
# still agree about a number.
#
# THE NUMBERS BELOW ARE TRANSCRIBED FROM THE PROGRAM, not derived from the code
# under test. `programs/turf_vault/src/state.rs`, `DEFAULT_THRESHOLDS` and
# `THRESHOLD_FLOORS`, read on turf-vault `accepted` 3ea4245b (2026-09-15). A
# test that asked `Governance` for the number and then asserted `Governance`
# returned it would pass on any table at all.
class Solana::GovernanceThresholdsTest < ActiveSupport::TestCase
  # ── THE SIX THAT BROKE ────────────────────────────────────────────────────
  #
  # These are the actions the operator cosign flow builds, and every one of
  # them rose to three. Rails supplied two: the server's admin key and one
  # Phantom cosigner. Each name here is a path that goes dark the day v0.26
  # deploys unless a third signature is collected.
  RAISED_TO_THREE = %w[
    settle_contest
    cancel_contest
    sweep_operator_revenue
    register_currency
    deactivate_currency
    unpause
  ].freeze

  test "every raised operator cosign action requires three signatures" do
    RAISED_TO_THREE.each do |action|
      assert_equal 3, Solana::Governance.required_signatures(action),
                   "#{action} is 3 in turf-vault DEFAULT_THRESHOLDS; a lower number here " \
                   "builds a transaction the chain will refuse"
    end
  end

  # ── THE ASYMMETRY THAT MUST SURVIVE ───────────────────────────────────────
  #
  # `pause` is 2 and `unpause` is 3, deliberately: a brake must be easier to
  # pull than the attack it stops, and nothing an agent can reach alone may
  # lift a brake its own capture would have triggered. Collapsing these two to
  # one number in the mirror would hand the higher cost to the brake and the
  # lower one to the release — the exact inversion the program refuses.
  test "pause stays cheaper than unpause" do
    assert_equal 2, Solana::Governance.required_signatures("pause")
    assert_equal 3, Solana::Governance.required_signatures("unpause")
    assert_operator Solana::Governance.required_signatures("pause"), :<,
                    Solana::Governance.required_signatures("unpause"),
                    "the brake must never cost more signatures than releasing it"
  end

  # Actions that did NOT rise. Asserted because a mirror that returned 3 for
  # everything would pass every test above while silently over-reserving slots
  # — and an over-reserved slot is not harmless on settle_contest, where it
  # shifts the settlement payload out from under the length check.
  test "actions that did not rise keep their lower thresholds" do
    assert_equal 2, Solana::Governance.required_signatures("close_contest")
    assert_equal 2, Solana::Governance.required_signatures("set_contest_lock_time")
    assert_equal 2, Solana::Governance.required_signatures("set_contest_conclusion_time")
    assert_equal 1, Solana::Governance.required_signatures("mint_entry_token")
    assert_equal 1, Solana::Governance.required_signatures("create_contest")
    assert_equal 1, Solana::Governance.required_signatures("enter_contest")
    assert_equal 1, Solana::Governance.required_signatures("grant_seeds")
  end

  # ── THE ESCALATED BRANCHES ────────────────────────────────────────────────
  #
  # The program picks these over their base action by reading ON-CHAIN contest
  # state, so a caller cannot tell from the Rails row alone which one it will
  # face. They are in the mirror — and NOT yet wired into a builder — so the
  # number is recorded where the next change will look for it rather than being
  # rediscovered. See the PR body: these are a named follow-up, not an
  # oversight.
  test "the escalated lock-time and conclusion branches are three" do
    assert_equal 3, Solana::Governance.required_signatures("set_contest_lock_time_reopen")
    assert_equal 3, Solana::Governance.required_signatures("set_contest_conclusion_time_amend")
  end

  # ── FLOORS ────────────────────────────────────────────────────────────────
  #
  # The program raises a stored value up to its floor ON READ. A mirror that
  # reported a retuned-below-floor number would under-reserve on exactly the
  # three actions the program refuses to let anyone weaken.
  test "floored actions never report below their floor" do
    { "update_signers" => 3, "unpause" => 3, "set_governance" => 3 }.each do |action, floor|
      assert_operator Solana::Governance.required_signatures(action), :>=, floor,
                      "#{action} is floored at #{floor} in THRESHOLD_FLOORS"
    end
  end

  # ── THE ACTION IDS ARE PERMANENT ──────────────────────────────────────────
  #
  # The program indexes its stored table by these numbers. Renumbering one
  # silently re-points a live stored threshold at a different action, so the
  # ids are pinned here as literals rather than left to drift.
  test "action ids match the program's permanent numbering" do
    expected = {
      "settle_contest" => 0, "cancel_contest" => 1, "sweep_operator_revenue" => 2,
      "register_currency" => 3, "deactivate_currency" => 4, "pause" => 5,
      "unpause" => 6, "update_signers" => 7, "create_season" => 8,
      "close_contest" => 9, "set_contest_lock_time" => 10,
      "set_contest_conclusion_time" => 11, "mint_entry_token" => 12,
      "mint_entry_token_over_cap" => 13, "burn_entry_token" => 14,
      "grant_seeds" => 15, "set_governance" => 16, "create_contest" => 18,
      "enter_contest" => 19, "set_contest_lock_time_reopen" => 20,
      "set_contest_conclusion_time_amend" => 21
    }
    expected.each do |action, id|
      assert_equal id, Solana::Governance::ACTION_IDS[action],
                   "#{action} is gov_action id #{id} and the id can never be reused"
    end
  end

  # ── AN UNKNOWN ACTION MUST NOT DEFAULT ────────────────────────────────────
  #
  # The tempting default is 1 — the program's own fallback for an id past the
  # end of its table. Here it would be a disaster: 1 reserves NO extra slot, so
  # a typo'd or renamed action silently builds the two-signature shape on a
  # three-signature path. That is the original bug, re-entered through a
  # convenience.
  test "an unknown action raises instead of defaulting to one" do
    error = assert_raises(Solana::Governance::UnknownActionError) do
      Solana::Governance.required_signatures("settle_contests")
    end
    assert_match(/settle_contests/, error.message)
    assert_match(/do not guess/i, error.message)
  end

  # ── THE SLOT ARITHMETIC ───────────────────────────────────────────────────
  #
  # `authorize` computes `required - named.len()` and reads exactly that many
  # LEADING remaining accounts. Computing it differently on this side is how
  # the two sides disagree about where the payload starts.
  test "extra slots are the threshold minus the named signers" do
    assert_equal 1, Solana::Governance.extra_cosigners_needed("settle_contest", named_count: 2)
    assert_equal 2, Solana::Governance.extra_cosigners_needed("settle_contest", named_count: 1)
    assert_equal 0, Solana::Governance.extra_cosigners_needed("close_contest", named_count: 2)
  end

  # `saturating_sub` on the program side floors at zero. An instruction whose
  # named signers already exceed its threshold must ask for NO extra accounts —
  # a negative count here would become a nonsense slice on the other side.
  test "extra slots never go negative" do
    assert_equal 0, Solana::Governance.extra_cosigners_needed("mint_entry_token", named_count: 2)
    assert_equal 0, Solana::Governance.extra_cosigners_needed("create_contest", named_count: 3)
  end
end
