# Public transparency page for the turf-vault smart contract.
#
# Phase 1 (current): static infographic — binary stats, ELF section
# breakdown, .text buckets, per-instruction cards, auth model, and a
# SOL→USD cost calculator. Numbers are hardcoded against v0.16 of the
# turf-vault program (see the turf-vault repo, docs/v0.16-spec.md).
#
# Phase 2 (not implemented here — depends on Carl's Solana::Vault
# refactor for the v0.16 VaultState layout): wire live `paused`,
# accepted-currencies, and operator-revenue balances. Hook points live
# on the partials as commented `<dd>` placeholders so the data layer can
# be plugged in without restructuring the view.
class ContractController < ApplicationController
  skip_before_action :require_authentication
  skip_before_action :require_profile_completion, raise: false

  def show
    # current_user&.admin? gates the operator sections in the view.
    # Phase 2: populate @live_vault_state from a cached Solana::Vault read,
    # rendered next to the static program-ID and "paused" placeholders.
  end
end
