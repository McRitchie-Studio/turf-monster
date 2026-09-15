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
      "unpause"                => "unpause"
    }.freeze

    # The signers every one of these instructions NAMES in its account struct:
    # `admin` and `cosigner`. `authorize` subtracts exactly this from the
    # threshold to size the remaining-account run, so it is the number that
    # decides how many slots to leave — not a guess, and not the same for every
    # instruction in the program (the two `set_contest_*_time` builders name
    # `admin` alone and encode `cosigner: None`).
    NAMED_SIGNER_COUNT = 2

    attr_reader :action, :tx_type

    def initialize(tx_type:)
      @tx_type = tx_type.to_s
      @action = TX_TYPE_ACTIONS.fetch(@tx_type) do
        raise InvalidCosignerError,
              "unsupported cosign tx_type #{tx_type.inspect} — add it to " \
              "Solana::CosignPlan::TX_TYPE_ACTIONS with the turf-vault action it builds."
      end
    end

    # Total vault signatures the chain will demand for this action.
    def required_signatures
      Governance.required_signatures(action)
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

      Governance.extra_cosigners_needed(action, named_count: NAMED_SIGNER_COUNT)
    end

    # Vault signers eligible to fill a Phantom slot: the on-chain signer set
    # minus the key the SERVER already signs with. Offering the admin key to
    # the operator would be offering a signature that is already spent —
    # `validate_threshold` counts DISTINCT members, so admin signing twice is
    # one signature and `DuplicateSigner` rejects the whole transaction.
    def self.eligible_cosigners
      Config::MULTISIG_SIGNERS - [admin_address].compact
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

      unknown = extras.reject { |a| Config::MULTISIG_SIGNERS.include?(a) }
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
    def roster(extras: [], fee_payer: nil)
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

      rows << {
        address: Config::MULTISIG_COSIGNER,
        role: "cosigner",
        label: "Cosigner",
        fee_payer: false,
        signs_automatically: false
      }

      Array(extras).compact.reject(&:blank?).each_with_index do |address, i|
        rows << {
          address: address,
          role: "extra",
          label: extras.length > 1 ? "Wallet #{i + 3}" : "Second wallet",
          fee_payer: false,
          signs_automatically: false
        }
      end

      rows
    end

        ELIGIBLE_HINT = "Eligible signers are the vault's on-chain set minus the server's admin key.".freeze
  end
end
