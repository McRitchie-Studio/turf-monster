require "test_helper"

# Solana::CosignPlan — how many wallets an operator cosign needs, and whether a
# proposed set of them can actually satisfy the action.
#
# ── WHY `Config.governance?` IS STUBBED RATHER THAN SET ───────────────────
#
# `Solana::Config::GOVERNANCE` is frozen at class load from the environment,
# and this build ships resolved to v0.25 (asserted in governance_switch_test).
# So the v0.26 branch cannot be reached by writing an env var mid-test. The
# code reads the SWITCH through `Config.governance?`, so that method is the
# seam — stubbing it exercises the real branch rather than a re-derivation of
# it. Every governance-shape test below goes through `with_governance`.
class Solana::CosignPlanTest < ActiveSupport::TestCase
  SIGNERS = Solana::Config::MULTISIG_SIGNERS
  PRIMARY = Solana::Config::MULTISIG_COSIGNER

  def with_governance(on = true, &block)
    Solana::Config.stub(:governance?, on, &block)
  end

  # A vault signer that is neither the admin key nor the named cosigner — the
  # only kind of wallet that can legitimately fill an extra slot.
  def spare_signer
    (Solana::CosignPlan.eligible_cosigners - [PRIMARY]).first
  end

  # ── THE SHAPE OF THE ASK ──────────────────────────────────────────────────

  test "a raised action needs one extra slot beyond the two named signers" do
    with_governance do
      plan = Solana::CosignPlan.new(tx_type: "settle_contest")
      assert_equal 3, plan.required_signatures
      assert_equal 1, plan.extra_cosigners_needed
      # The server signs as admin; everything else is Phantom's.
      assert_equal 2, plan.browser_signatures_needed
    end
  end

  test "every raised cosign tx_type asks for an extra slot" do
    with_governance do
      %w[settle_contest cancel_contest sweep_operator_revenue
         register_currency deactivate_currency unpause].each do |tx_type|
        plan = Solana::CosignPlan.new(tx_type: tx_type)
        assert_equal 3, plan.required_signatures, "#{tx_type} needs three signatures"
        assert_equal 1, plan.extra_cosigners_needed,
                     "#{tx_type} must reserve a third signer slot or the chain refuses it"
      end
    end
  end

  # ── THE v0.25 SHAPE MUST STAY UNTOUCHED ───────────────────────────────────
  #
  # The switch exists so the changeover is a config write, not a deploy. That
  # promise only holds if the governance-off path is identical to what shipped:
  # no extra slots, and no new refusals.
  test "governance off reserves nothing and refuses nothing" do
    with_governance(false) do
      plan = Solana::CosignPlan.new(tx_type: "settle_contest")
      assert_equal 0, plan.extra_cosigners_needed
      assert_equal [], plan.validate_extras!(nil, primary: PRIMARY)
      assert_equal [], plan.validate_extras!([], primary: PRIMARY)
    end
  end

  # A pre-governance build names admin and cosigner, and on this test box those
  # two can be the SAME key. That was true before this change and must stay
  # acceptable to the planner — judging a named pair it did not choose would be
  # a behaviour change smuggled in through a validator.
  test "governance off does not judge the named signers" do
    with_governance(false) do
      plan = Solana::CosignPlan.new(tx_type: "settle_contest")
      assert_equal [], plan.validate_extras!([], primary: Solana::CosignPlan.admin_address)
    end
  end

  # ── THE REFUSALS ──────────────────────────────────────────────────────────

  test "too few extra cosigners is refused before a transaction is built" do
    with_governance do
      plan = Solana::CosignPlan.new(tx_type: "settle_contest")
      error = assert_raises(Solana::CosignPlan::InvalidCosignerError) do
        plan.validate_extras!([], primary: PRIMARY)
      end
      assert_match(/settle_contest needs 3 vault signatures/, error.message)
      assert_match(/got 0/, error.message)
    end
  end

  # OVER-RESERVING IS NOT HARMLESS, which is why it is refused rather than
  # trimmed. `authorize` consumes only `required - named.len()` leading
  # remaining accounts; on settle_contest the rest is the settlement payload,
  # so a surplus slot shifts that payload and the length check fails.
  test "too many extra cosigners is refused rather than trimmed" do
    with_governance do
      plan = Solana::CosignPlan.new(tx_type: "settle_contest")

      # The COUNT is checked before membership, so this asserts the surplus is
      # refused without needing two spare signers in the configured set — the
      # count is the property under test, not who the second wallet is.
      error = assert_raises(Solana::CosignPlan::InvalidCosignerError) do
        plan.validate_extras!([spare_signer, PRIMARY], primary: PRIMARY)
      end
      assert_match(/got 2/, error.message)
      assert_match(/settle_contest needs 3 vault signatures/, error.message)
    end
  end

  test "a pubkey outside the vault signer set is refused" do
    with_governance do
      plan = Solana::CosignPlan.new(tx_type: "settle_contest")
      error = assert_raises(Solana::CosignPlan::InvalidCosignerError) do
        plan.validate_extras!(["NotAVaultSigner1111111111111111111111111111"], primary: PRIMARY)
      end
      assert_match(/not in the vault signer set/, error.message)
      assert_match(/Unauthorized/, error.message)
    end
  end

  # A DUPLICATE IS A REJECTION, NOT A SHORTFALL. `validate_threshold` refuses a
  # repeated key outright with DuplicateSigner and fails the whole transaction,
  # so "pass one more key" would be the wrong remedy. The message has to say
  # which reading applies or the operator debugs the wrong one.
  test "reusing the named cosigner as the extra is refused as a duplicate" do
    with_governance do
      plan = Solana::CosignPlan.new(tx_type: "settle_contest")
      error = assert_raises(Solana::CosignPlan::InvalidCosignerError) do
        plan.validate_extras!([PRIMARY], primary: PRIMARY)
      end
      assert_match(/more than once/, error.message)
      assert_match(/DuplicateSigner/, error.message)
    end
  end

  test "reusing the server's admin key as the extra is refused as a duplicate" do
    admin = Solana::CosignPlan.admin_address
    skip "no admin key configured" if admin.blank?
    skip "admin key is not in the signer set here" unless SIGNERS.include?(admin)

    with_governance do
      plan = Solana::CosignPlan.new(tx_type: "settle_contest")
      error = assert_raises(Solana::CosignPlan::InvalidCosignerError) do
        plan.validate_extras!([admin], primary: PRIMARY)
      end
      assert_match(/more than once/, error.message)
    end
  end

  # ── WHAT A VALID SET LOOKS LIKE ───────────────────────────────────────────

  test "a distinct in-set signer is accepted and returned in order" do
    spare = spare_signer
    skip "needs a spare vault signer beyond admin and the named cosigner" if spare.blank?

    with_governance do
      plan = Solana::CosignPlan.new(tx_type: "settle_contest")
      assert_equal [spare], plan.validate_extras!([spare], primary: PRIMARY)
    end
  end

  # ── ELIGIBILITY ───────────────────────────────────────────────────────────
  #
  # Offering the admin key to the operator would be offering a signature that
  # is already spent: the server signs with it at build time, and a second use
  # is a duplicate, not a second signature.
  test "the admin key is never offered as an eligible cosigner" do
    admin = Solana::CosignPlan.admin_address
    skip "no admin key configured" if admin.blank?

    refute_includes Solana::CosignPlan.eligible_cosigners, admin,
                    "the server already signs with the admin key; offering it again is a duplicate"
  end

  # ── AN UNSUPPORTED TYPE MUST NOT SILENTLY PLAN ZERO ───────────────────────

  test "an unsupported tx_type raises rather than planning no signatures" do
    error = assert_raises(Solana::CosignPlan::InvalidCosignerError) do
      Solana::CosignPlan.new(tx_type: "drain_treasury")
    end
    assert_match(/drain_treasury/, error.message)
  end
end
