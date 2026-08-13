require "test_helper"

# OnboardingFlow — which post-auth steps a user still owes, in order.
#
# The ORDER is the product decision (operator, 2026-08-12): welcome → first name
# → age → wallet. Everything else here is about a step dropping out once it is
# satisfied, so the chain a user walks is only what they have left.
class OnboardingFlowTest < ActiveSupport::TestCase
  def setup
    ENV["ENABLE_WEB3_ONLY_ONBOARDING"] = "true"
  end

  def teardown
    ENV.delete("ENABLE_WEB3_ONLY_ONBOARDING")
  end

  # A brand-new account: no first name, no DOB, no wallet.
  def fresh_user
    user = users(:jordan)
    user.update_columns(first_name: nil, name: nil, age_attested_at: nil,
                        web2_solana_address: nil, web3_solana_address: nil)
    user
  end

  test "a brand-new signup walks the full chain in order" do
    steps = OnboardingFlow.steps_for(fresh_user, welcome: true, age_gate_enabled: true)
    assert_equal [:welcome, :first_name, :age, :wallet], steps,
                 "the operator's order is welcome -> first name -> age -> wallet"
  end

  test "the order is fixed, not the order the caller happens to ask in" do
    # STEPS is the single source of order; the selection must not reorder it.
    assert_equal [:welcome, :first_name, :age, :wallet], OnboardingFlow::STEPS
  end

  test "a returning login gets no welcome beat" do
    steps = OnboardingFlow.steps_for(fresh_user, welcome: false, age_gate_enabled: true)
    assert_equal [:first_name, :age, :wallet], steps
    assert_not_includes steps, :welcome
  end

  test "a user who already has a first name is not asked again" do
    user = fresh_user
    user.update_columns(first_name: "Alex")
    assert_not_includes OnboardingFlow.steps_for(user, age_gate_enabled: true), :first_name
  end

  test "skipping the first name drops it for the session" do
    steps = OnboardingFlow.steps_for(fresh_user, skipped_first_name: true, age_gate_enabled: true)
    assert_not_includes steps, :first_name
    # …and does NOT swallow the rest of the chain.
    assert_equal [:age, :wallet], steps
  end

  test "a verified DOB drops the age step" do
    user = fresh_user
    user.update_columns(age_attested_at: Time.current)
    assert_not_includes OnboardingFlow.steps_for(user, age_gate_enabled: true), :age
  end

  test "the age step never appears while the age gate is off" do
    # ENABLE_AGE_GATE off: there is nothing to collect, so asking would be noise.
    assert_not_includes OnboardingFlow.steps_for(fresh_user, age_gate_enabled: false), :age
  end

  test "the wallet step defers to WalletSetupPolicy, not its own rule" do
    # One rule for "needs a wallet", shared with the entry gate — so a
    # grandfathered web2 user holding an entry's worth of USDC is not asked here
    # either. Asserted by STUBBING the policy: if this test still passed with the
    # policy saying no, the chain would be deciding on its own.
    user = fresh_user
    WalletSetupPolicy.stub :required_for?, false do
      assert_not_includes OnboardingFlow.steps_for(user, age_gate_enabled: true), :wallet
    end
    WalletSetupPolicy.stub :required_for?, true do
      assert_includes OnboardingFlow.steps_for(user, age_gate_enabled: true), :wallet
    end
  end

  test "a fully set-up returning user owes nothing" do
    user = fresh_user
    user.update_columns(first_name: "Alex", age_attested_at: Time.current,
                        web3_solana_address: "PhantomLinked#{user.id}")
    assert_empty OnboardingFlow.steps_for(user, age_gate_enabled: true),
                 "a settled account must see no chain at all"
  end

  test "no user means no chain" do
    assert_empty OnboardingFlow.steps_for(nil, welcome: true, age_gate_enabled: true)
  end
end
