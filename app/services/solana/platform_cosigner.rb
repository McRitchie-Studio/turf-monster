module Solana
  # THE PLATFORM'S SECOND VAULT SIGNATURE.
  #
  # Mr. McRitchie's ruling (platform-cosigns-mainnet-settles), after being asked for two Phantom
  # signatures on one settle: "You need two signatures? We should have it so
  # you can do two signatures and I'm only important if you need a third."
  #
  # So on a three-signature VaultState action the platform supplies two
  # signatures itself: the server's admin key (SOLANA_ADMIN_KEY, `4S39…` on
  # mainnet) and this key, the agent cosigner (`3LTL…`, 1Password
  # `solana.turf.governance.v2`). His wallet is always the third and final
  # signature. On QA/devnet the same seat is the devnet governance key
  # (`BVQH…`, `solana.turf.governance.devnet`).
  #
  # ── WHAT THIS CLASS DECIDES, AND WHAT IT DOES NOT ─────────────────────────
  #
  # It loads SOLANA_PLATFORM_COSIGNER_KEY and refuses any key that is not this
  # cluster's filed platform cosigner: a key that derives to one of
  # Mr. McRitchie's own wallets, to the server's admin key, or to anything
  # other than the filed address. A refused or absent key leaves the app on
  # the behaviour that predates this class (the server signs once, the
  # operator signs every other slot) with a notice on the Treasury page. It
  # never raises at boot and never crashes a page.
  #
  # WHEN it signs is Solana::CosignPlan's call (#platform_cosign?,
  # #platform_completes?): automatically on a settle, on an explicit admin
  # click for the other three-signature actions, and only ever when at least
  # one signature is still left for Mr. McRitchie on a three-signature action.
  #
  # ── WHY A NEW VARIABLE AND NOT SOLANA_COSIGNER_KEYS ───────────────────────
  #
  # SOLANA_COSIGNER_KEYS (Keypair.cosigners) is a WINDOW variable: Steffon sets
  # it for one sitting and unsets it, and `contests:nfl_sunday_lock` signs
  # with whatever it holds. This key is standing production config with one
  # job and a filed address per cluster. Folding it into the window list would
  # hand the lock rake a standing second key, and a name one letter away
  # (SOLANA_COSIGNER_KEY) would invite exactly that mistake.
  class PlatformCosigner
    ENV_KEY = "SOLANA_PLATFORM_COSIGNER_KEY".freeze

    # The filed PUBLIC key per cluster. A key that derives to anything else is
    # refused. Mainnet: VaultState slot 0. Devnet: a seated devnet signer
    # (docs/agents/modules/credentials.md lists the devnet set).
    EXPECTED_ADDRESSES = {
      "mainnet-beta" => "3LTLPG1s952sdNatZWtnfM7r9F3ivWSnPSqfhQLBepJ9",
      "devnet"       => "BVQHNwUEo91ePwqPcR6Ro4g9Ejqt3qn3ajKPqJSSTd51"
    }.freeze

    # The platform signs these the moment they are built (grade time, and
    # every rebuild): a settle needs only Mr. McRitchie's one signature.
    AUTOMATIC_TX_TYPES = %w[settle_contest].freeze

    # The other three-signature actions: the platform signs only when the
    # operator asks, per build. The Treasury rows ask with a checkbox; an
    # update_signers asks from the signer console. Unpause (its own page,
    # /admin/vault_state) has no platform path yet and keeps two wallets.
    ON_REQUEST_TX_TYPES = %w[cancel_contest sweep_operator_revenue register_currency
                             deactivate_currency update_signers].freeze

    # Two-signature actions the server and this key may COMPLETE alone, from
    # an explicit admin click. Every completion is written to the
    # PendingTransaction and to the hub activity feed.
    COMPLETABLE_TX_TYPES = %w[close_contest].freeze

    STATES = %i[configured absent refused].freeze

    class NotConfigured < StandardError; end

    attr_reader :state, :address, :reason, :network

    # The process-wide instance, loaded once. Tests call .reset!.
    def self.current
      @current ||= load
    end

    def self.reset!
      @current = nil
    end

    def self.load(env: ENV, network: Config::NETWORK, roster: nil, admin_address: :read,
                  expected: :filed)
      secret = env[ENV_KEY].to_s.strip
      expected = EXPECTED_ADDRESSES[network.to_s] if expected == :filed
      return new(:absent, network: network, reason: "#{ENV_KEY} is not set") if secret.empty?

      keypair = parse_secret(secret)
      unless keypair
        return new(:refused, network: network,
                             reason: "#{ENV_KEY} is neither a base58 secret key nor a 64-byte JSON array")
      end

      address = keypair.to_base58
      refusal = refusal_for(address, network: network, expected: expected,
                                     roster: roster || SignerRoster.default,
                                     admin_address: admin_address == :read ? CosignPlan.admin_address : admin_address)
      return new(:refused, network: network, address: address, reason: refusal) if refusal

      new(:configured, network: network, address: address, keypair: keypair)
    end

    # SOLANA_ADMIN_KEY's base58 form, or a Solana CLI keypair file's 64-byte
    # JSON array (how a 1Password item may store it). Nil when neither; the
    # value is never echoed.
    def self.parse_secret(secret)
      if secret.start_with?("[")
        bytes = JSON.parse(secret)
        return nil unless bytes.is_a?(Array) && bytes.size == 64 && bytes.all? { |b| b.is_a?(Integer) && b.between?(0, 255) }

        keypair = Keypair.from_bytes(bytes)
        return keypair if keypair.public_key_bytes == bytes.last(32).pack("C*")

        return nil
      end

      Keypair.from_base58(secret)
    rescue StandardError
      nil
    end

    # Why `address` may not be the platform cosigner, or nil when it may.
    # Mr. McRitchie's keys are refused FIRST and by two independent sources
    # (the roster's `holder: alex` and the config defaults that name his
    # Phantom), so a roster edit alone cannot seat his key on a dyno.
    def self.refusal_for(address, network:, expected:, roster:, admin_address:)
      alex = roster.operator?(address) ||
             [Config::MULTISIG_COSIGNER, Config::INIT_AUTHORITY].include?(address)
      if alex
        return "#{ENV_KEY} derives to #{address}, one of Mr. McRitchie's own wallets; " \
               "the platform never holds his key"
      end
      if admin_address.present? && address == admin_address
        return "#{ENV_KEY} derives to the server's own key #{address}; a second copy of " \
               "one key is not a second signature (turf-vault refuses it as DuplicateSigner)"
      end
      if expected.blank?
        return "#{ENV_KEY} has no filed platform cosigner for #{network}, so #{address} is refused"
      end
      return nil if address == expected

      "#{ENV_KEY} derives to #{address}, but the #{network} platform cosigner is #{expected}"
    end

    def initialize(state, network:, address: nil, reason: nil, keypair: nil)
      raise ArgumentError, "unknown state #{state.inspect}" unless STATES.include?(state)

      @state = state
      @network = network.to_s
      @address = address
      @reason = reason
      @keypair = keypair
    end

    def configured? = state == :configured

    # Fill this key's signature slot in a partially signed wire, base64 in and
    # out. The slot must exist and be empty (Transaction.cosign_wire refuses a
    # clobber); the wire stays incomplete for the operator's wallet.
    def sign_wire_base64(wire_base64)
      raise NotConfigured, notice unless configured?

      bytes = Transaction.cosign_wire(Base64.decode64(wire_base64.to_s), signer: @keypair,
                                                                          require_complete: false)
      Base64.strict_encode64(bytes)
    end

    # The keypair, for builders that sign in-process (the eviction console's
    # server-held cosigners, the two-signature completion). Raises unless
    # configured.
    def keypair
      raise NotConfigured, notice unless configured?

      @keypair
    end

    # One sentence for the Treasury page and the boot log. Public keys only.
    def notice
      case state
      when :configured
        "The platform cosigner #{address} signs beside the server key."
      when :absent
        "#{reason}, so the platform supplies only the server's signature and every other " \
          "signature comes from Mr. McRitchie's wallets."
      else
        "The platform cosigner is refused: #{reason}. Until Steffon fixes it, every signature " \
          "beyond the server's comes from Mr. McRitchie's wallets."
      end
    end

    # The boot line, logged like the signer-isolation line beside it.
    def report = "[platform-cosigner] #{network}: #{notice}"

    def inspect = "#<#{self.class.name} #{state} #{address || '-'}>"
  end
end
