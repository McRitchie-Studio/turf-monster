# The public /contract page's signer matrix, derived rather than typed.
#
# The matrix used to hard-code "1-of-3" and "2-of-3" and name three people
# (Xan, Mr. McRitchie, Mason). The 2026-10-14 mainnet rotation retired two of
# those keys and v0.26 made every threshold per-action data, so the copy went
# stale the day the chain moved. These helpers read the two sources that move
# with the chain instead:
#
#   - the signer COUNT: Solana::Config::MULTISIG_SIGNERS (the VaultState set);
#   - each action's THRESHOLD: Solana::Governance.required_signatures, the
#     program's shipped defaults. Mainnet's stored GovernanceConfig table
#     matched them for every action on 2026-10-14. The page makes no RPC call:
#     a retune by set_action_threshold changes the defaults' meaning, not this
#     page, so a retune owes this page a look (docs/SOLANA.md, "v0.26 signature
#     thresholds").
#
# The holders sentence counts keys by Solana::SignerRoster `holder`, so it
# names roles, never a retired nickname. Public copy: no "Alex" (the agent
# orchestrator holds no key here).
module ContractHelper
  # The vault actions the matrix shows, in reading order within a tier.
  VAULT_MATRIX_ACTIONS = %w[
    create_contest mint_entry_token
    set_contest_lock_time set_contest_conclusion_time close_contest pause
    create_season register_currency deactivate_currency settle_contest cancel_contest
    sweep_operator_revenue unpause update_signers
  ].freeze

  def vault_signer_count
    Solana::Config::MULTISIG_SIGNERS.size
  end

  def vault_threshold(action)
    Solana::Governance.required_signatures(action)
  end

  # "2-of-5": the compact label the instruction cards and playbook use.
  def vault_auth_label(action)
    "#{vault_threshold(action)}-of-#{vault_signer_count}"
  end

  # { threshold => [actions] }, lowest threshold first.
  def vault_signer_tiers(actions = VAULT_MATRIX_ACTIONS)
    actions.group_by { |action| vault_threshold(action) }.sort.to_h
  end

  # "3 held by Mr. McRitchie and 2 by the app's agents", counted from the
  # roster's `holder` field for each configured signer. A key the roster does
  # not know is counted as unlisted rather than guessed.
  def vault_signer_holders_sentence
    roster = Solana::SignerRoster.default
    entries = Solana::Config::MULTISIG_SIGNERS.map { |address| roster[address] }
    owner = entries.count { |entry| entry&.alex? }
    agents = entries.count { |entry| entry && !entry.alex? }
    unlisted = entries.count(&:nil?)

    parts = []
    parts << "#{owner} held by Mr. McRitchie" if owner.positive?
    parts << "#{agents} by the app's agents" if agents.positive?
    parts << "#{unlisted} not yet named in the app's roster" if unlisted.positive?
    parts.to_sentence
  end
end
