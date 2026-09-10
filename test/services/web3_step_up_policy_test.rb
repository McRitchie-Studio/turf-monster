require "test_helper"

# Web3StepUpPolicy — does THIS SESSION owe a wallet signature?
#
# The population is one intersection, and the tests are organised around
# defending its edges: an account with a self-custody wallet whose CURRENT
# session came from a web2 credential. Move either fact and the answer flips.
class Web3StepUpPolicyTest < ActiveSupport::TestCase
  # sam holds a web3_solana_address in the fixtures — a self-custody account.
  def wallet_user
    users(:sam)
  end

  # jordan has no wallet of either kind unless one is given.
  def web2_user
    user = users(:jordan)
    user.update_columns(web3_solana_address: nil, web2_solana_address: "managedaddr1111111111111111111111111111111")
    user
  end

  test "a wallet account on a web2 session owes a step-up" do
    assert Web3StepUpPolicy.required_for?(wallet_user, session_mode: :web2)
  end

  test "the same account on a web3 session owes nothing" do
    # They signed THIS session, which is the very thing a step-up asks for.
    assert_not Web3StepUpPolicy.required_for?(wallet_user, session_mode: :web3)
  end

  test "a managed-wallet account on a web2 session owes nothing" do
    # This is the ordinary web2 player. The session they just established serves
    # them completely; there is no second credential to reach for.
    assert_not Web3StepUpPolicy.required_for?(web2_user, session_mode: :web2)
  end

  test "a guest owes a login, not a step-up" do
    assert_not Web3StepUpPolicy.required_for?(nil, session_mode: :guest)
  end

  # The two policies must never fire at the same user — one asks "should this
  # account GET a wallet", the other "should this SESSION prove the wallet it
  # has". Overlapping would stack two modals on one render.
  test "it is disjoint from WalletSetupPolicy" do
    ENV["ENABLE_WEB3_ONLY_ONBOARDING"] = "true"
    user = wallet_user
    assert Web3StepUpPolicy.required_for?(user, session_mode: :web2)
    assert_not WalletSetupPolicy.required_for?(user),
               "a phantom account exits WalletSetupPolicy at its own step 1 — if that " \
               "ever changes, a wallet owner gets the setup modal AND the step-up card"
  ensure
    ENV.delete("ENABLE_WEB3_ONLY_ONBOARDING")
  end

  # --- provider memory --------------------------------------------------------

  test "it reports the remembered brand and its label" do
    wallet_user.update_columns(web3_wallet_provider: "phantom")
    policy = Web3StepUpPolicy.new(wallet_user, session_mode: :web2)
    assert_equal "phantom", policy.provider
    assert_equal "Phantom", policy.provider_label
  end

  test "an unremembered wallet reports nil, which is the picker fallback" do
    # Every account that linked a wallet before the column existed is here, so
    # this is a live population rather than a defensive branch.
    wallet_user.update_columns(web3_wallet_provider: nil)
    policy = Web3StepUpPolicy.new(wallet_user, session_mode: :web2)
    assert_nil policy.provider
    assert_nil policy.provider_label
  end

  test "a brand that is no longer in the registry degrades to the picker" do
    # A column value can outlive its registry entry (a wallet we stop shipping
    # artwork for). Reading it back through normalize is what keeps that a
    # graceful fallback instead of a modal painting an empty icon.
    wallet_user.update_columns(web3_wallet_provider: "retired-wallet")
    assert_nil Web3StepUpPolicy.new(wallet_user, session_mode: :web2).provider
  end

  test "the wallet hint shows four leading and four trailing characters" do
    wallet_user.update_columns(web3_solana_address: "foUuRyeibadQoGdKXZ9pBGDqmkb1jY1jYsu8dZ29nds")
    assert_equal "foUu…9nds", Web3StepUpPolicy.new(wallet_user, session_mode: :web2).wallet_hint
  end

  test "a too-short address yields no hint rather than a misleading one" do
    wallet_user.update_columns(web3_solana_address: "abc123")
    assert_nil Web3StepUpPolicy.new(wallet_user, session_mode: :web2).wallet_hint
  end

  test "to_h carries exactly what the modal reads" do
    wallet_user.update_columns(web3_wallet_provider: "solflare",
                               web3_solana_address: "foUuRyeibadQoGdKXZ9pBGDqmkb1jY1jYsu8dZ29nds")
    assert_equal({ provider: "solflare", providerLabel: "Solflare", walletHint: "foUu…9nds" },
                 Web3StepUpPolicy.new(wallet_user, session_mode: :web2).to_h)
  end

  # The policy is on the render path (web3_step_up_required? is a helper_method),
  # so an RPC here would cost every page view. WalletSetupPolicy pays that cost
  # deliberately and once, at sign-in; this one must never pay it at all.
  test "it issues no Solana RPC" do
    Solana::Vault.stub :new, ->(*) { raise "Web3StepUpPolicy must not touch the chain" } do
      assert Web3StepUpPolicy.required_for?(wallet_user, session_mode: :web2)
      assert_not Web3StepUpPolicy.required_for?(wallet_user, session_mode: :web3)
    end
  end
end
