module Solana
  # Who must sign one operator cosign transaction, and whether a proposed set
  # of signers can actually satisfy it.
  #
  # ── THE DEFECT THIS EXISTS TO CLOSE ───────────────────────────────────────
  #
  # Every operator cosign path supplied exactly TWO vault signatures: the
  # server's admin key, patched into its slot after the fact, and ONE Phantom
  # signature from `Config::MULTISIG_COSIGNER`. Under turf-vault v0.26 six of
  # those paths need THREE (`settle_contest`, `cancel_contest`,
  # `sweep_operator_revenue`, `register_currency`, `deactivate_currency`,
  # `unpause`), so each one reaches the chain one signature short.
  #
  # Five fail 6046 `InsufficientSigners`, because `authorize` checks
  # `remaining.len() >= extra_needed` against an empty remaining list. The
  # sixth, `settle_contest`, is the odd one and the nastiest: it is the only
  # instruction that ALSO uses `remaining_accounts` for payload, so the first
  # settlement's `user_account` sits where the third cosigner should be,
  # `info.is_signer` is false, and it fails 6047 `CosignerDidNotSign` instead.
  # Debugging the six from the 6046 pattern sends you looking in the wrong
  # place for that one. The builders have always had the `extra_cosigners:`
  # slot; nothing in production ever passed it.
  #
  # ── WHY THE SIGNER LIST IS REQUESTED, NOT CONFIGURED ──────────────────────
  #
  # The extra signer slots are reserved at BUILD time, by pubkey, before any
  # signature exists — so something has to name the wallets before the operator
  # touches Phantom. That could have been a second `SOLANA_MULTISIG_COSIGNER_2`
  # env var, and was not, for one reason: the VaultState signer set is MID
  # ROTATION from three slots to five, and the wallets Mr. McRitchie can
  # actually reach are not the wallets that were in the set when this shipped.
  # A pinned env var would need a coordinated config change on the day of the
  # rotation, on the exact paths that go dark if it is wrong.
  #
  # So the browser names the wallets it is about to collect from, and this
  # class refuses anything the chain would refuse. That is safe because it
  # widens nothing: `VaultState::is_signer` is the real gate, and a pubkey that
  # is not in the on-chain set fails `Unauthorized` no matter what Rails
  # believed. The checks here exist to fail in Rails, with a sentence naming
  # the action and the shortfall, instead of spending a fee to be told 6046.
  class CosignPlan
    # A proposed signer set that cannot satisfy the action. Raised in Rails,
    # before a transaction is built — never a program error code.
    class InvalidCosignerError < StandardError; end

    # PendingTransaction#tx_type → the turf-vault governance action it builds.
    # Every supported type happens to share its instruction's name today; the
    # map is explicit anyway, because `Governance.required_signatures` refuses
    # an unknown action rather than defaulting it, and a silent rename would
    # otherwise reserve zero cosigner slots on a three-signature action.
    TX_TYPE_ACTIONS = {
      "settle_contest"         => "settle_contest",
      "cancel_contest"         => "cancel_contest",
      "register_currency"      => "register_currency",
      "deactivate_currency"    => "deactivate_currency",
      "sweep_operator_revenue" => "sweep_operator_revenue",
      "unpause"                => "unpause",
      # close_contest names only `admin`; the primary cosigner rides in the
      # first remaining account instead of a named slot, so the count below
      # (server + one Phantom = 2) still matches CLOSE_CONTEST.
      "close_contest"          => "close_contest",
      # EVICTION. Three signatures, and FLOORED at three — `set_action_threshold`
      # cannot lower it, which is what stops three signatures handing the vault
      # back to two agent-reachable keys the next day. Driven from
      # /admin/authorities; see Admin::AuthoritiesController.
      "update_signers"         => "update_signers"
    }.freeze

    # The signers every one of these instructions NAMES in its account struct:
    # `admin` and `cosigner`. `authorize` subtracts exactly this from the
    # threshold to size the remaining-account run, so it is the number that
    # decides how many slots to leave — not a guess, and not the same for every
    # instruction in the program (the two `set_contest_*_time` builders name
    # `admin` alone and encode `cosigner: None`).
    NAMED_SIGNER_COUNT = 2

    attr_reader :action, :tx_type

    # `vault:` is the reader for the chain's GovernanceConfig. Optional: the
    # plan builds its own Solana::Vault when none is passed, and only on a
    # governance boot.
    def initialize(tx_type:, vault: nil)
      @vault = vault
      @tx_type = tx_type.to_s
      @action = TX_TYPE_ACTIONS.fetch(@tx_type) do
        raise InvalidCosignerError,
              "unsupported cosign tx_type #{tx_type.inspect} — add it to " \
              "Solana::CosignPlan::TX_TYPE_ACTIONS with the turf-vault action it builds."
      end
    end

    # Total vault signatures the chain will demand for this action.
    #
    # ON A GOVERNANCE (v0.26) BOOT THIS IS THE CHAIN'S NUMBER. It used to be the
    # compiled default, so a `set_action_threshold` retune reached the program
    # and never reached this plan: retune settle to 2 and the console still
    # reserved a third slot, which `settle_contest` reads as payload and refuses;
    # retune anything above the default and the plan reserved too few, which the
    # chain refuses with 6046. The stored table is read once per plan (one
    # minute of cache under it, Vault#cached_governance) and goes through the
    # program's own `threshold_for` (zero reads as the default, floors on read).
    # An unreadable or absent GovernanceConfig — between the upgrade and
    # `init_governance` — falls back to the shipped defaults, which fail closed.
    #
    # On a v0.25 boot nothing is read: the answer is the compiled default, as it
    # always was (PendingTransaction#required_signatures documents why that
    # number is governance-independent there).
    def required_signatures
      return Governance.required_signatures(action) unless Config.governance?

      Governance.required_signatures(action, thresholds: chain_thresholds)
    end

    # How many signatures the browser must collect beyond the one the server
    # contributes. The server signs as `admin`; the named `cosigner` slot and
    # every extra slot are Phantom's.
    def browser_signatures_needed
      required_signatures - 1
    end

    # How many EXTRA (remaining-account) cosigner slots to reserve. Zero on a
    # v0.25 boot and on any action the two named signers already satisfy — in
    # which case the whole flow is byte-identical to what shipped.
    def extra_cosigners_needed
      return 0 unless Config.governance?

      Governance.extra_cosigners_needed(action, named_count: NAMED_SIGNER_COUNT, thresholds: chain_thresholds)
    end

    # ── THE PLATFORM'S SECOND SIGNATURE (platform-cosigns-mainnet-settles) ──
    #
    # Whether THIS build takes the platform cosigner (Solana::PlatformCosigner)
    # in the named `cosigner` slot, so the server signs admin and cosigner and
    # Mr. McRitchie's wallets fill only the extra slots.
    #
    # THE INVARIANT IS `extra_cosigners_needed.positive?`: the platform fills
    # the two NAMED slots and never an extra one, so it may sign only when at
    # least one extra slot is left for him. That is "his wallet is always the
    # third" stated as arithmetic, and it is what keeps a v0.25 boot (no extra
    # slots, two signatures complete the action) and a devnet settle retuned
    # to two from ever being finished by agent keys alone.
    #
    # Automatic for a settle; on request for the other three-signature types.
    def platform_cosign?(requested: false, platform: PlatformCosigner.current)
      return false unless platform.configured?
      return false unless extra_cosigners_needed.positive?
      return false unless self.class.signer_set.include?(platform.address)
      return true if PlatformCosigner::AUTOMATIC_TX_TYPES.include?(tx_type)

      ActiveModel::Type::Boolean.new.cast(requested) == true &&
        PlatformCosigner::ON_REQUEST_TX_TYPES.include?(tx_type)
    end

    # Whether the server and the platform cosigner may COMPLETE this action
    # alone, from an explicit admin click. Only a two-signature action, only
    # on a governance boot (where two is the chain's number, not the v0.25
    # shape), and only a type listed in COMPLETABLE_TX_TYPES.
    def platform_completes?(platform: PlatformCosigner.current)
      platform.configured? &&
        Config.governance? &&
        PlatformCosigner::COMPLETABLE_TX_TYPES.include?(tx_type) &&
        required_signatures == 2 &&
        self.class.signer_set.include?(platform.address)
    end

    # The vault's seated signers, which is the set a cosigner must belong to.
    #
    # v0.26 has FIVE slots (`signers` + `signers_ext`) and Config::MULTISIG_SIGNERS
    # is an env-overridable literal that can lag the chain. Judging membership against
    # the config list would refuse a wallet a rotation seated since it was written
    # — a valid third signature the chain would accept — so a governance boot
    # reads VaultState's active slots (Vault.cached_vault_state, one request /
    # one minute). Unreadable falls back to the config list; v0.25 never reads.
    def self.signer_set
      return Config::MULTISIG_SIGNERS unless Config.governance?

      seated = begin
        Vault.cached_vault_state&.dig(:active_signers)
      rescue StandardError
        nil
      end
      Array(seated).presence || Config::MULTISIG_SIGNERS
    end

    # Vault signers eligible to fill a Phantom slot: the on-chain signer set
    # minus the key the SERVER already signs with. Offering the admin key to
    # the operator would be offering a signature that is already spent —
    # `validate_threshold` counts DISTINCT members, so admin signing twice is
    # one signature and `DuplicateSigner` rejects the whole transaction.
    #
    # ORDERED BY THE OPERATOR'S PRIORITY, NOT BY SLOT. Mr. McRitchie's own
    # keys lead, in config/signer_roster.yml `priority` order; every other
    # seated key (agent-held, or unknown to the roster) follows in slot order.
    # Slot order used to stand here, and mainnet slot 0 is 3LTL, the agent
    # governance key, so the co-sign card for ptx-437 offered it
    # as the default second wallet. The order is free to choose: turf-vault's
    # `validate_threshold` tests set MEMBERSHIP and distinctness, never which
    # slot a key sits in, so any seated key may fill any remaining-account slot.
    def self.eligible_cosigners
      SignerRoster.default.by_operator_priority(signer_set - [admin_address].compact)
    end

    # The wallets to PRESELECT for `count` extra slots, out of `eligible`:
    # Mr. McRitchie's keys only, in priority order. Agent keys stay
    # selectable (3LTL is his break-glass copy) but are never chosen for him.
    # Shorter than `count` when too few of his keys are seated; the caller
    # then renders an unchosen slot rather than reaching for an agent key.
    def self.default_extras(eligible, count)
      roster = SignerRoster.default
      Array(eligible).select { |address| roster.operator?(address) }.first(count.to_i)
    end

    # The server's own vault signer address, or nil when this process holds no
    # admin key. Nil rather than a raise: the eligibility list is rendered on a
    # page that must still load on a box with no signing key configured.
    def self.admin_address
      Keypair.admin.to_base58
    rescue StandardError
      nil
    end

    # Validate the EXTRA cosigners a request proposes, and return them in the
    # order their slots will be reserved.
    #
    # `primary` is the named `cosigner` slot — already reserved by the builder,
    # and therefore already spent as far as distinctness goes.
    #
    # Order matters and is preserved: `authorize` reads the leading
    # `remaining_accounts` positionally, so the pubkey in slot one must be the
    # pubkey whose signature lands in slot one.
    def validate_extras!(requested, primary:)
      extras = Array(requested).map { |a| a.to_s.strip }.reject(&:blank?)
      needed = extra_cosigners_needed

      # NOTHING TO ADD, NOTHING TO JUDGE. On a v0.25 boot, and on any action
      # whose two named signers already satisfy its threshold, this plan
      # contributes no slots — and a validator that went on to inspect the
      # NAMED signers would be judging a build it is not part of. It would also
      # be a behaviour change smuggled in sideways: the pre-governance shape
      # must stay byte-identical, which means it must also stay refusal-
      # identical. Returning early is what keeps "governance off" genuinely off.
      return [] if needed.zero? && extras.empty?

      if extras.length != needed
        raise InvalidCosignerError,
              "#{action} needs #{required_signatures} vault signatures, so #{needed} extra " \
              "cosigner#{'s' unless needed == 1} must be named beyond admin and #{primary} " \
              "— got #{extras.length}. #{ELIGIBLE_HINT}"
      end

      seated = self.class.signer_set
      unknown = extras.reject { |a| seated.include?(a) }
      if unknown.any?
        raise InvalidCosignerError,
              "#{unknown.join(', ')} is not in the vault signer set, so turf-vault would " \
              "reject this transaction with Unauthorized. #{ELIGIBLE_HINT}"
      end

      # DISTINCTNESS IS NOT A COUNTING RULE HERE — it is a rejection rule.
      # `VaultState::validate_threshold` refuses a repeated key outright with
      # `DuplicateSigner` and fails the WHOLE transaction, so a duplicate does
      # not merely count for less than it looks. "Pass one more key" would be
      # the wrong remedy even when the count is right.
      already_spent = [self.class.admin_address, primary.to_s].compact.reject(&:blank?)
      duplicated = extras.select { |e| already_spent.include?(e) } |
                   extras.tally.select { |_, n| n > 1 }.keys
      if duplicated.any?
        raise InvalidCosignerError,
              "#{duplicated.join(', ')} would sign this transaction more than once. " \
              "turf-vault requires every vault signature to come from a DISTINCT signer and " \
              "rejects a repeat with DuplicateSigner, so the transaction fails outright " \
              "rather than counting short. Choose #{needed} signer#{'s' unless needed == 1} " \
              "other than admin and #{primary}."
      end

      extras
    end

    # The wallets this transaction needs, IN SIGNING ORDER, for the roster the
    # operator reads while he works.
    #
    # WHY A ROSTER AT ALL. Three signatures is enough state to lose track of,
    # and the operator is switching wallets inside an extension while he does
    # it. Without a visible "what is done and what is next" he is reconstructing
    # that from memory between Phantom dialogs — which is how a console that let
    # him press Execute at 2 of 3 wasted a transaction.
    #
    # ORDER IS THE SIGNING ORDER, not a display preference: the server signs
    # first as `admin` (it is also the fee payer), then the named `cosigner`
    # slot, then each extra remaining-account slot in the order it was reserved.
    # turf-vault reads those accounts positionally.
    #
    # `fee_payer_status` is passed IN rather than read here, because it costs an
    # RPC round trip and this method is called per row on a page that may render
    # many. The caller reads it once.
    def roster(extras: [], fee_payer: nil, platform_cosigner: nil)
      admin = self.class.admin_address
      rows = []

      # NIL IS LOAD-BEARING HERE — do not compact this hash. `balance_sol: nil`
      # means the balance could not be READ, which the roster must render
      # differently from a balance of zero: zero blocks, unknown does not.
      rows << {
        address: admin,
        role: "server",
        label: "Server (fee payer)",
        fee_payer: true,
        signs_automatically: true,
        balance_sol: fee_payer && fee_payer[:balance_sol],
        funded: fee_payer && fee_payer[:funded],
        minimum_sol: fee_payer && fee_payer[:minimum_sol]
      }

      # With the platform cosigner the named slot is the server's second
      # signature, not a Phantom prompt: it signs automatically, and the
      # extras below are the only wallets the operator is asked for.
      rows << if platform_cosigner.present?
        {
          address: platform_cosigner,
          role: "platform",
          label: "Platform cosigner",
          fee_payer: false,
          signs_automatically: true
        }
      else
        {
          address: Config::MULTISIG_COSIGNER,
          role: "cosigner",
          label: "Cosigner",
          fee_payer: false,
          signs_automatically: false
        }
      end

      # A BLANK extra is a slot not chosen yet (none of Mr. McRitchie's keys
      # was seated to preselect). It keeps its row, so the page shows a slot
      # still to fill and cosign.js repoints THAT row when he picks, rather
      # than the named cosigner's row above it.
      extras = Array(extras).map(&:to_s)
      extras.each_with_index do |address, i|
        rows << {
          address: address.presence,
          role: "extra",
          label: if extras.length > 1 then "Wallet #{i + 3}"
                 elsif platform_cosigner.present? then "Your wallet (the final signature)"
                 else "Second wallet"
                 end,
          fee_payer: false,
          signs_automatically: false
        }
      end

      rows
    end

    private

    # The stored GovernanceConfig threshold table, or nil (defaults) when it
    # cannot be read. Memoized per plan so one plan never mixes two readings.
    def chain_thresholds
      return @chain_thresholds if defined?(@chain_thresholds)

      @chain_thresholds = begin
        (@vault || Vault.new).cached_governance&.dig(:thresholds)
      rescue StandardError
        nil
      end
    end

    public

    ELIGIBLE_HINT = "Eligible signers are the vault's on-chain set minus the server's admin key.".freeze
  end
end
