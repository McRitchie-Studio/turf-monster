# frozen_string_literal: true

# NO TEST READS THE LIVE DEVNET GOVERNANCE TABLE.
#
# With SOLANA_VAULT_GOVERNANCE stubbed on, `Solana::Vault#required_signatures`
# reads the GovernanceConfig account through `cached_governance`. The test env
# points at public devnet, so a test that did not stub that read asked the REAL
# chain. Until 2026-10-12 the devnet account did not exist, the read answered
# nil, and the shipped defaults applied, so those tests passed by accident. Then
# devnet ran init_governance and retuned settle_contest to 2 (card
# devnet-v026-upgrade), and they failed on every branch with "Expected 3,
# Actual 2" — a test outcome decided by an on-chain operator action.
#
# The same day moved the devnet VaultState signer set, and
# `CosignPlan.signer_set` reads it live (`cached_vault_state`), so a test's
# extras were judged against whoever devnet seated that morning.
#
# So: a governance or VaultState read through a REAL client pointed at a
# PUBLIC cluster answers nil under test (the shipped defaults; the app's own MULTISIG_SIGNERS). A vault
# built with a fake client still decodes whatever that fake returns, and a per-test `stub`/`define_singleton_method`
# on any of these readers still wins (singleton methods
# resolve before this prepended module).
module HermeticGovernanceRead
  LOOPBACK = %w[127.0.0.1 localhost ::1 [::1]].freeze

  def read_governance(**kwargs)
    return nil if public_cluster_client?

    super
  end

  def read_vault_state(**kwargs)
    return nil if public_cluster_client?

    super
  end

  private

  # A real client pointed at a public cluster. The opt-in local-validator proof
  # (TURF_VAULT_V026_VALIDATOR=1, bin/v026-local-validator-proof) reads a
  # loopback validator it booted itself, so its reads go through.
  def public_cluster_client?
    return false unless client.is_a?(Solana::Client)
    return false if ENV["TURF_VAULT_V026_VALIDATOR"] == "1"

    host = client.instance_variable_get(:@uri)&.host
    !LOOPBACK.include?(host)
  end
end

Solana::Vault.prepend(HermeticGovernanceRead)
