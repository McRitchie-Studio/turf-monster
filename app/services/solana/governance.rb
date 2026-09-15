module Solana
  # The per-action signature thresholds turf-vault v0.26 enforces, mirrored in
  # Ruby so a builder can ask "how many signatures does this action need?"
  # BEFORE it assembles an account list.
  #
  # ── WHY A MIRROR EXISTS AT ALL ────────────────────────────────────────────
  #
  # The authority is the on-chain `GovernanceConfig` PDA, and nothing here
  # changes that: `instructions::governance::authorize` reads the stored table
  # and this app cannot overrule it. What Rails needs is not the verdict but
  # the SHAPE — how many `remaining_accounts` signer slots to leave empty —
  # and that has to be decided at build time, before any signature exists.
  #
  # Until this file, every threshold in the app was a bare literal at a call
  # site (`unattended_extra_signer_metas("create_season", required: 3, …)`).
  # Seven literals, no cross-check, and the SIX OPERATOR COSIGN PATHS had none
  # at all — which is exactly how they came to supply two signatures against a
  # threshold of three. A number that lives in one place can be wrong; a number
  # that lives in seven places drifts silently.
  #
  # ── WHAT THIS MIRROR IS AND IS NOT ────────────────────────────────────────
  #
  # It is the program's compiled-in DEFAULTS plus its FLOORS. It is NOT the
  # stored table: `set_action_threshold` can retune any unfloored entry, and a
  # retune lands here as a build that reserves too few or too many slots.
  #   * TOO FEW  → the chain refuses (6046 InsufficientSigners, or 6047
  #                CosignerDidNotSign when a payload account fills the slot).
  #                Loud, and the transaction never lands.
  #   * TOO MANY → `authorize` consumes only `required - named.len()` leading
  #                remaining accounts, so a surplus signer slot is simply never
  #                read as a cosigner. For `settle_contest` that is NOT benign:
  #                the surplus shifts the settlement payload, so the split
  #                `remaining[cosigners_consumed..]` lands mid-payload and the
  #                length check fails. Never over-reserve.
  # Both directions fail closed. Neither silently under-authorizes.
  #
  # So: when a threshold is retuned on chain, this file must follow. It is
  # deliberately a plain table rather than an RPC read — an RPC in the build
  # path would put a network round trip on every settle and would still be a
  # snapshot by the time the transaction is signed.
  #
  # Source of truth: turf-vault `programs/turf_vault/src/state.rs`,
  # `DEFAULT_THRESHOLDS` and `THRESHOLD_FLOORS`. Read at `accepted`
  # 3ea4245b on 2026-09-15.
  module Governance
    # Action ids, mirroring `state.rs::gov_action`. PERMANENT — the program
    # indexes its stored threshold table by these numbers, so renumbering one
    # silently re-points a stored threshold at a different action. Only the
    # actions this app actually builds are listed; the ids are the program's.
    ACTION_IDS = {
      "settle_contest"                => 0,
      "cancel_contest"                => 1,
      "sweep_operator_revenue"        => 2,
      "register_currency"             => 3,
      "deactivate_currency"           => 4,
      "pause"                         => 5,
      "unpause"                       => 6,
      "update_signers"                => 7,
      "create_season"                 => 8,
      "close_contest"                 => 9,
      "set_contest_lock_time"         => 10,
      "set_contest_conclusion_time"   => 11,
      "mint_entry_token"              => 12,
      "mint_entry_token_over_cap"     => 13,
      "burn_entry_token"              => 14,
      "grant_seeds"                   => 15,
      "set_governance"                => 16,
      "create_contest"                => 18,
      "enter_contest"                 => 19,
      # The two ESCALATED branches. The program picks these over their base
      # action by reading ON-CHAIN contest state at execution time:
      #   reopen — the contest's stored lock_timestamp is set AND already past
      #   amend  — the contest's stored conclusion_timestamp is already non-zero
      # Rails cannot pick between the pair from its own database, because the
      # program reads the CONTEST ACCOUNT, not the row. Any caller that builds
      # one of these must decide from an on-chain read or reserve for the
      # escalated number. See `docs/SOLANA.md` "escalated branches".
      "set_contest_lock_time_reopen"       => 20,
      "set_contest_conclusion_time_amend"  => 21
    }.freeze

    # Signatures each action requires, mirroring `DEFAULT_THRESHOLDS`.
    #
    # The design intent, in the program's own words: anything that MOVES MONEY
    # or CHANGES WHO GOVERNS needs three; the brake needs fewer signatures than
    # the attack; and nothing an agent can reach on its own may lift a brake
    # the agent's own capture would have triggered. That is why `pause` is 2
    # and `unpause` is 3.
    DEFAULT_THRESHOLDS = {
      "settle_contest"                    => 3,
      "cancel_contest"                    => 3,
      "sweep_operator_revenue"            => 3,
      "register_currency"                 => 3,
      "deactivate_currency"               => 3,
      "pause"                             => 2,
      "unpause"                           => 3,
      "update_signers"                    => 3,
      "create_season"                     => 3,
      "close_contest"                     => 2,
      "set_contest_lock_time"             => 2,
      "set_contest_conclusion_time"       => 2,
      "mint_entry_token"                  => 1,
      "mint_entry_token_over_cap"         => 3,
      "burn_entry_token"                  => 3,
      "grant_seeds"                       => 1,
      "set_governance"                    => 3,
      "create_contest"                    => 1,
      "enter_contest"                     => 1,
      "set_contest_lock_time_reopen"      => 3,
      "set_contest_conclusion_time_amend" => 3
    }.freeze

    # Immovable floors, mirroring `THRESHOLD_FLOORS`. The program raises a
    # stored value up to these ON READ, so a floor holds even against a table
    # written by a path that forgot to check. Mirrored here so this module
    # cannot report a number the chain would refuse to honour.
    THRESHOLD_FLOORS = {
      "update_signers" => 3,
      "unpause"        => 3,
      "set_governance" => 3
    }.freeze

    # Raised when an action name reaches this module that the program has no id
    # for. A typo must never resolve to a default — the default would be 1, and
    # a 1 here reserves no cosigner slot at all on an action that needs three.
    class UnknownActionError < StandardError; end

    # Signatures `action` requires. Never returns less than the program's floor.
    def self.required_signatures(action)
      key = action.to_s
      unless ACTION_IDS.key?(key)
        raise UnknownActionError,
              "unknown governance action #{action.inspect} — turf-vault indexes its threshold " \
              "table by a fixed id per action (see Solana::Governance::ACTION_IDS). Add the " \
              "action here with the id state.rs::gov_action gives it; do not guess a number."
      end

      [DEFAULT_THRESHOLDS.fetch(key, 1), THRESHOLD_FLOORS.fetch(key, 1)].max
    end

    # How many EXTRA signer slots a builder must leave in `remaining_accounts`
    # for `action`, given how many signers the instruction NAMES in its account
    # struct.
    #
    # This is `authorize`'s own arithmetic, deliberately: it computes
    # `extra_needed = required - named.len()` and reads exactly that many
    # LEADING remaining accounts as cosigners. Computing it the same way on
    # both sides is what makes the account-list split deterministic across the
    # wire, and `saturating_sub` is why this floors at zero rather than going
    # negative — an instruction whose named signers already satisfy its
    # threshold needs no extra slots and no client change.
    def self.extra_cosigners_needed(action, named_count:)
      [required_signatures(action) - named_count.to_i, 0].max
    end

    # True when `action` needs more signatures than the pre-governance (v0.25)
    # shape could express. `validate_multisig` was structurally exactly two
    # signatures and never read a threshold, so two is the whole of what the
    # old shape could produce.
    def self.raised_above_legacy?(action)
      required_signatures(action) > 2
    end
  end
end
