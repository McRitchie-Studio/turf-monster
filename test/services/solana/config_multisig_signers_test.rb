# frozen_string_literal: true

require "test_helper"

# [unit] Solana::Config::DEFAULT_MULTISIG_SIGNERS is the literal every app
# without SOLANA_MULTISIG_SIGNERS runs on. turf-monster-mainnet ran on it until
# 2026-10-14, and while it still named the retired 8K81/7ZDJ/CytJ set the cosign
# guards (pending_transactions_controller, vault_state_controller) refused
# Mr. McRitchie's new wallets. The mainnet signer fence is the file a rotation
# ceremony updates, so the literal is pinned to its `seated` list, in slot order.
class Solana::ConfigMultisigSignersTest < ActiveSupport::TestCase
  FENCE = Rails.root.join("config/mainnet_vault_signers.yml")

  def fence
    YAML.safe_load_file(FENCE)
  end

  test "the default signer set is the mainnet VaultState set the fence files as seated, in slot order" do
    seated = fence.fetch("seated")
    assert_equal 5, seated.size, "fixture: v0.26 VaultState has five slots"
    assert_equal seated, Solana::Config::DEFAULT_MULTISIG_SIGNERS
  end

  test "the default names no key a mainnet rotation retired" do
    retired = fence.fetch("retired")
    assert_includes retired, "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd", "fixture: the retired list is the one the rotation wrote"
    assert_empty Solana::Config::DEFAULT_MULTISIG_SIGNERS & retired
  end

  test "the default holds the production server key and the operator's Phantom cosigner" do
    assert_includes Solana::Config::DEFAULT_MULTISIG_SIGNERS, "4S39sKHHPV8GPjUif9noN9gdsAFGs9WASuGxs7B9s5CY"
    assert_includes Solana::Config::DEFAULT_MULTISIG_SIGNERS, Solana::Config::MULTISIG_COSIGNER
  end
end
