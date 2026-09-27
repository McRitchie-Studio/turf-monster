module Solana
  # THE DRY RUN FOR GIVING turf-monster-qa ITS OWN SIGNING KEY
  # (task separate-qa-solana-signing-key; runbook
  # docs/qa-signing-key-rotation.md; CLI bin/qa-signer-rotation).
  #
  # It reads the devnet VaultState, works out the signer set the ceremony
  # would write, judges that set against turf-vault's own guards, and prints
  # what Mr. McRitchie signs. It builds no transaction, holds no key, and can
  # send nothing — the client it reads through ANSWERS ONLY get_account_info
  # (ReadOnlyClient below), so a send path would have to be added on purpose,
  # not reached by accident.
  #
  # ── WHY A QA-SPECIFIC LAYER OVER Solana::SignerRotation ──────────────────
  #
  # SignerRotation already knows the program's rules, in the program's order,
  # for both deployed shapes, and this class hands every set to it. What it
  # does not know is what THIS ceremony is for: the new key must be a real
  # public key, must not already sit in the set, and must not be another
  # environment's system wallet — a QA key equal to production's would make
  # the whole ceremony a no-op that looks like a fix. Those checks come from
  # config/solana_signers.yml, the same registry the isolation guard reads.
  #
  # ── DEVNET ONLY ──────────────────────────────────────────────────────────
  #
  # QA runs devnet; production runs mainnet-beta, and each cluster's VaultState
  # is its own account. This ceremony touches the devnet vault and nothing
  # else, so the class refuses to plan against any other cluster or program.
  class QaSignerRotation
    DEVNET = "devnet".freeze
    DEVNET_PROGRAM_ID = "EQGFJAcABtDb6VXtiijTjZ6cE2UqdvhnqJvoharJbpMJ".freeze
    MAINNET_PROGRAM_ID = "DaFv83yokwTz8msP9CzJ13eazSGk15NuUTxjkfzJzxMM".freeze

    # The cluster or program is not the devnet vault. Raised before any read.
    class WrongCluster < StandardError; end

    # A client that can READ and nothing else. Every other RPC method —
    # send_transaction, simulate_transaction, send_and_confirm, request_airdrop
    # — raises before it reaches the network.
    class ReadOnlyClient
      class WriteRefused < StandardError; end

      def initialize(inner)
        @inner = inner
      end

      def get_account_info(*args, **kwargs)
        @inner.get_account_info(*args, **kwargs)
      end

      def method_missing(name, *)
        raise WriteRefused, "bin/qa-signer-rotation is read-only; #{name} is not available to it"
      end

      def respond_to_missing?(_name, _include_private = false) = false
    end

    Result = Struct.new(:shape, :current, :proposed, :authorizers, :evicted, :added,
                        :required, :refusals, :notes, keyword_init: true) do
      def ok? = refusals.empty?
    end

    def self.devnet_vault(rpc_url: Config::PUBLIC_CLUSTER_RPC_URLS.fetch(DEVNET))
      Vault.new(client: ReadOnlyClient.new(Config.client(rpc_url: rpc_url)))
    end

    def initialize(qa_pubkey:, cosigners:, replace: nil, append: false, vault:,
                   registry: SignerIsolation::Registry.load,
                   network: Config::NETWORK, program_id: Config::PROGRAM_ID)
      @qa_pubkey = qa_pubkey.to_s.strip
      @cosigners = Array(cosigners).map { |k| k.to_s.strip }.reject(&:empty?)
      @replace = replace.to_s.strip.presence
      @append = append
      @vault = vault
      @registry = registry
      @network = network
      @program_id = program_id
    end

    # The current set and program shape, for `--show`. Guarded like #plan.
    def show
      guard_cluster!
      state = @vault.read_vault_state
      return "the devnet VaultState could not be found at program #{@program_id}" if state.nil?

      self.class.render_show(state, @vault.read_governance)
    end

    def plan
      guard_cluster!

      vault_state = @vault.read_vault_state
      if vault_state.nil?
        return refused("the devnet VaultState could not be found at program #{@program_id}")
      end

      governance = @vault.read_governance
      shape = governance ? "v0.26" : "v0.25"
      current_slots = Array(vault_state[:signer_slots]).first(governance ? SignerRotation::MAX_SLOTS_V026 : SignerRotation::MAX_SLOTS_V025)
      current = vault_state[:active_signers]
      notes = shape_notes(governance)

      refusals = qa_key_refusals(current) + strategy_refusals(current, governance)
      proposed = refusals.empty? ? proposed_set(current_slots) : current

      rotation = SignerRotation.for_chain(
        current_signers: current,
        proposed: proposed,
        authorizers: @cosigners,
        governance: !governance.nil?,
        max_live_threshold: governance && Governance.max_live_threshold(governance[:thresholds])
      )
      if refusals.empty? && (message = rotation.refusal_message)
        refusals << message
      end

      Result.new(shape: shape, current: current, proposed: rotation.live_slots, authorizers: @cosigners,
                 evicted: rotation.evicted, added: rotation.added, required: rotation.required,
                 refusals: refusals, notes: notes)
    end

    # What the operator reads. Public keys only — there is nothing else here.
    def self.render(result, qa_pubkey:, registry: SignerIsolation::Registry.load)
      production = registry.system_wallet("production")
      lines = []
      lines << "QA signer rotation — DRY RUN (devnet only; nothing is signed or sent)"
      lines << ""
      result.notes.each { |n| lines << "  #{n}" }
      lines << "" if result.notes.any?
      lines << "  current set : #{result.current.join(', ')}" if result.current.any?
      lines << "  planned set : #{result.proposed.join(', ')}" if result.ok?
      lines << "  adds        : #{result.added.join(', ')}" if result.ok?
      lines << "  evicts      : #{result.evicted.empty? ? '(nobody)' : result.evicted.join(', ')}" if result.ok?
      lines << "  signed by   : #{result.authorizers.join(', ')} (#{result.required} required)" if result.required

      unless result.ok?
        lines << ""
        lines << "REFUSED — turf-vault would reject this plan, or it would not isolate QA:"
        result.refusals.each { |r| lines << "  - #{r}" }
        return lines.join("\n")
      end

      lines << ""
      lines << "PLAN PASSES every rule this tool checks. The chain is still the real gate."
      if result.evicted.include?(production)
        lines << ""
        lines << "  ! It evicts #{production}, production's system wallet, from the DEVNET vault."
        lines << "    Local development and the devnet e2e lane sign as that key, so they lose devnet"
        lines << "    vault authority until they are re-pointed. Mainnet is unaffected."
      end
      lines << ""
      lines << "Mr. McRitchie signs it himself (docs/qa-signing-key-rotation.md, step 6):"
      if result.shape == "v0.25"
        lines << "  1. Sign in to turf-monster-qa as an admin and open /admin/authorities."
        lines << "  2. In the eviction form, enter exactly these values, in this order:"
        result.proposed.each_with_index { |key, i| lines << "       slot #{i + 1}       : #{key}" }
        result.authorizers.each_with_index do |key, i|
          lines << "       authorizer #{i + 1} : #{key}#{' (lead, pays the fee)' if i.zero?}"
        end
        lines << "     When the lead is QA's current server key, the server signs that slot itself;"
        lines << "     every other authorizer is a Phantom signature."
        lines << "  3. Collect the signatures, broadcast, and let the page read the set back."
      else
        lines << "  # from a turf-vault checkout"
        lines << "  node scripts/rotate-devnet-signers.js --slots #{result.proposed.join(',')} \\"
        lines << "    #{result.authorizers.map { |a| "--signer <keypair file for #{a}>" }.join(' ')}"
        lines << "  (a dry run until you add --send; /admin/authorities on turf-monster-qa builds the same set)"
      end
      lines << ""
      lines << "Then verify, read-only:"
      lines << "  bin/qa-signer-rotation --show        # must list #{qa_pubkey}"
      lines << "Only AFTER the chain lists the QA key: set SOLANA_ADMIN_KEY on turf-monster-qa (runbook step 8)."
      lines.join("\n")
    end

    # The current set and shape, nothing planned.
    def self.render_show(vault_state, governance)
      shape = governance ? "v0.26 (GovernanceConfig present)" : "v0.25 (no GovernanceConfig)"
      lines = ["devnet VaultState #{vault_state[:pda]} — program shape #{shape}"]
      Array(vault_state[:signer_slots]).each_with_index do |key, i|
        lines << format("  [%d] %s", i, key == SignerRotation::EMPTY ? "(empty)" : key)
      end
      lines.join("\n")
    end

    private

    def guard_cluster!
      if @program_id == MAINNET_PROGRAM_ID || @network.to_s == "mainnet-beta"
        raise WrongCluster, "refusing: this is the MAINNET vault. The QA ceremony changes devnet only; " \
                            "mainnet's signer set is untouched by it."
      end
      return if @network.to_s == DEVNET && @program_id == DEVNET_PROGRAM_ID

      raise WrongCluster, "refusing: expected the devnet vault (#{DEVNET} / #{DEVNET_PROGRAM_ID}), " \
                          "got #{@network.inspect} / #{@program_id.inspect}"
    end

    def refused(message)
      Result.new(shape: nil, current: [], proposed: [], authorizers: @cosigners, evicted: [], added: [],
                 required: nil, refusals: [message], notes: [])
    end

    def qa_key_refusals(current)
      out = []
      unless SignerIsolation.valid_pubkey?(@qa_pubkey) && @qa_pubkey != SignerRotation::EMPTY
        return ["--qa-pubkey is not a 32-byte base58 public key"]
      end

      owner = @registry.other_wallets("qa").find { |_, wallet| wallet == @qa_pubkey }&.first
      out << "#{@qa_pubkey} is #{owner}'s system wallet; QA must hold a key of its own" if owner
      out << "#{@qa_pubkey} is already a devnet vault signer; there is nothing to add" if current.include?(@qa_pubkey)
      out
    end

    def strategy_refusals(current, governance)
      if @replace && @append
        ["pass --replace or --append, not both"]
      elsif @append
        return [] if governance

        ["--append needs the two v0.26 signer slots, and devnet runs v0.25 (no GovernanceConfig): " \
         "the deployed program takes exactly three signers. Use --replace, or upgrade devnet to v0.26 first"]
      elsif @replace
        current.include?(@replace) ? [] : ["--replace #{@replace} is not a current devnet vault signer"]
      else
        ["say how the QA key joins the set: --replace <current signer> or --append"]
      end
    end

    # Replace keeps every other key IN ITS SLOT; append takes the first empty
    # slot, which is the only one turf-vault's left-packing allows.
    def proposed_set(current_slots)
      live = current_slots.reject { |k| k.blank? || k == SignerRotation::EMPTY }
      @append ? live + [@qa_pubkey] : live.map { |k| k == @replace ? @qa_pubkey : k }
    end

    def shape_notes(governance)
      if governance
        ["devnet runs v0.26 (GovernanceConfig present): five slots, update_signers needs " \
         "#{Governance.required_signatures('update_signers')} signatures"]
      else
        ["devnet runs v0.25 (no GovernanceConfig): three fixed slots, exactly two signatures, and " \
         "BOTH signers must stay in the new set. If devnet was upgraded to v0.26 but init_governance " \
         "has not run, update_signers cannot run at all until it does"]
      end
    end
  end
end
