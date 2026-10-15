module Solana
  # The signer console's plan: from an INTENT (replace, add, remove) to the
  # new signer set, who signs it, and how many Phantom prompts that costs.
  #
  # ── WHY DERIVE, NOT ASK ─────────────────────────────────────────────────
  #
  # The console it replaces asked the operator for the whole slot list and the
  # signing wallets by hand. Every failure of its last live session came from
  # that: a slot left empty, the lead and cosigner swapped, Phantom asked for
  # the server's own key, a trailing full stop accepted. Here the operator says
  # what should change and this class computes the rest from rules:
  #
  #   1. The server leads whenever its key is seated and stays.
  #   2. Server-held cosigners (SOLANA_COSIGNER_KEYS) that stay sign next.
  #   3. Mr. McRitchie's seated accounts that stay fill the rest, chosen AND
  #      prompted in his roster priority (config/signer_roster.yml
  #      `priority`: 7ZDJ, 3Qj4, 9gAC). Only roster `holder: alex` keys are
  #      ever asked for in Phantom.
  #
  # Only keys that SURVIVE the rotation sign it, which satisfies continuity on
  # both program shapes (v0.25: both signers survive; v0.26: `required` of the
  # authorizers survive).
  #
  # It writes nothing and builds nothing. `Solana::SignerRotation` stays the
  # validator of the set; this class adds the derivation on top and refuses,
  # with a code, anything it or the chain would refuse.
  class SignerPlan
    INTENTS = %w[replace add remove].freeze

    # A refusal the console renders inline, on the same draft. `code` is a
    # stable string the browser and the tests key on; `chain_code` is the
    # turf-vault error number when the refusal stands in for one.
    class Refusal < StandardError
      attr_reader :code, :chain_code, :error_name, :field

      def initialize(message, code:, chain_code: nil, error_name: nil, field: nil)
        @code = code
        @chain_code = chain_code
        @error_name = error_name
        @field = field
        super(message)
      end

      def to_h
        { ok: false, code: code, chain_code: chain_code, error_name: error_name,
          field: field, message: message }
      end
    end

    attr_reader :network, :governance, :current, :required, :max_live_threshold,
                :server, :server_held, :roster, :connected, :nonce_ready

    # `governance:` is the CHAIN's shape (GovernanceConfig present), never the
    # app switch. `server_held:` are PUBLIC addresses only.
    def initialize(network:, governance:, current:, required:, server:, server_held: [],
                   roster: SignerRoster.default, max_live_threshold: nil, connected: nil,
                   nonce_ready: false)
      @network = network.to_s
      @governance = governance
      @current = Array(current).map { |k| k.to_s.strip }.reject { |k| k.blank? || k == SignerRotation::EMPTY }
      @required = required.to_i
      @max_live_threshold = max_live_threshold
      @server = server.presence
      @server_held = Array(server_held).map(&:to_s) - [@server]
      @roster = roster
      @connected = connected.to_s.strip.presence
      # Whether the signer console's durable nonce is ready (Solana::ConsoleNonce).
      # A server-led rotation then has no signing clock; an operator-led one
      # never anchors on it.
      @nonce_ready = nonce_ready == true
    end

    def mainnet? = network == "mainnet-beta"

    def max_slots = governance ? SignerRotation::MAX_SLOTS_V026 : SignerRotation::MAX_SLOTS_V025

    def shape = governance ? "v0.26" : "v0.25"

    # Every shape-dependent fact, so the browser carries no shape literal.
    def rules
      {
        shape: shape,
        network: network,
        max_slots: max_slots,
        required: required,
        max_live_threshold: max_live_threshold,
        intents: INTENTS.index_with { |intent| intent_refusal(intent) },
        continuity: if governance
                      "#{required} of the wallets that sign a rotation must stay in the new set."
                    else
                      "Both wallets that sign a rotation must stay in the new set."
                    end,
        server: server,
        server_seated: server.present? && current.include?(server),
        server_held: server_held,
        operator_led_allowed: !mainnet?
      }
    end

    # Who each address is, for the page. Unknown keys say so.
    def labels(addresses)
      Array(addresses).compact.uniq.reject { |a| a == SignerRotation::EMPTY }.index_with do |address|
        entry = roster[address]
        {
          name: entry&.name || "Unknown key",
          holder: entry&.holder,
          signs_in: entry&.signs_in,
          op_item: entry&.op_item,
          unknown: entry.nil?,
          server: address == server,
          server_held: server_held.include?(address),
          connected: address == connected
        }
      end
    end

    # The roster keys that could be added on this cluster: not seated now.
    def candidates
      roster.for_cluster(network).map(&:address) - current
    end

    # The plan, or raises Refusal. `confirm_unknown` lists added keys the
    # operator typed twice because the roster does not know them.
    def plan!(intent:, remove: [], add: [], confirm_unknown: [])
      intent = intent.to_s
      raise Refusal.new("Choose replace, add or remove.", code: "unknown_intent") unless INTENTS.include?(intent)

      reason = intent_refusal(intent)
      raise Refusal.new(reason, code: "intent_not_allowed", field: "intent") if reason

      remove = clean_list(remove)
      add = clean_list(add)
      check_removals!(remove)
      check_additions!(add, confirm_unknown: clean_list(confirm_unknown))
      proposed = proposed_set(intent, remove, add)

      authorizers, lead_is_server = derive_signers!(proposed)

      rotation = SignerRotation.for_chain(
        current_signers: current, proposed: proposed, authorizers: authorizers,
        governance: governance, max_live_threshold: max_live_threshold
      )
      begin
        rotation.validate!
      rescue SignerRotation::Refusal => e
        raise Refusal.new(e.message, code: "chain_rule", chain_code: e.code, error_name: e.error_name)
      end

      held = authorizers & server_held
      queue = authorizers - [lead_is_server ? server : nil].compact - (lead_is_server ? held : [])

      rotation.to_plan.merge(
        ok: true,
        intent: intent,
        remove: remove,
        add: add,
        network: network,
        lead_signer: authorizers.first,
        server_leads: lead_is_server,
        server_held: lead_is_server ? held : [],
        phantom_queue: queue,
        prompt_count: queue.length,
        no_time_limit: lead_is_server && nonce_ready,
        sentence: sentence(lead_is_server, lead_is_server ? held : [], queue),
        labels: labels(current + proposed + authorizers)
      )
    end

    private

    def clean_list(values)
      values = values.split(",") if values.is_a?(String)
      Array(values).map { |v| v.to_s.strip }.reject(&:blank?)
    end

    def intent_refusal(intent)
      case intent
      when "replace"
        nil
      when "add"
        return "The deployed program (#{shape}) has no empty slot, so a key can only replace another." unless governance
        return "All #{max_slots} slots are filled, so a key can only replace another." if current.length >= max_slots

        nil
      when "remove"
        return "The deployed program (#{shape}) takes exactly #{max_slots} signers, so a key can only be replaced." unless governance

        floor = [required, max_live_threshold.to_i].max
        return "The set holds #{current.length} keys and cannot go below #{floor}." if current.length <= floor

        nil
      end
    end

    def check_removals!(remove)
      remove.each do |key|
        next if current.include?(key)

        raise Refusal.new("#{short(key)} is not seated, so it cannot be removed or replaced.",
                          code: "not_seated", field: "remove")
      end
      return if remove.uniq.length == remove.length

      raise Refusal.new("A key is named twice for removal.", code: "duplicate_key", field: "remove")
    end

    def check_additions!(add, confirm_unknown:)
      add.each do |key|
        bytes = decode(key)
        if bytes.nil? || bytes.bytesize != 32
          shown = key.length > 50 ? "A #{key.length}-character value (not shown)" : "\"#{key}\""
          raise Refusal.new("#{shown} is not a Solana address (32 bytes of base58). " \
                            "Check for a character pasted with it.", code: "bad_address", field: "add")
        end
        if bytes == ("\x00" * 32).b
          raise Refusal.new("The zero key is the empty slot, not a signer.", code: "zero_key", field: "add")
        end
        # A program-derived (off-curve) address has no private key, so a slot
        # holding one can never sign.
        unless Transaction.on_curve?(bytes)
          raise Refusal.new("#{short(key)} is not on the ed25519 curve (a program-derived address), so " \
                            "no wallet can ever sign for it.", code: "off_curve", field: "add")
        end
        if current.include?(key)
          raise Refusal.new("#{short(key)} is already seated.", code: "already_seated", field: "add")
        end
        if !roster.include?(key) && !confirm_unknown.include?(key)
          raise Refusal.new("#{short(key)} matches no roster entry. Enter it a second time to confirm " \
                            "you mean an unknown key.", code: "unknown_key_unconfirmed", field: "add")
        end
      end
      return if add.uniq.length == add.length

      raise Refusal.new("A key is named twice to add.", code: "duplicate_key", field: "add")
    end

    def proposed_set(intent, remove, add)
      case intent
      when "replace"
        if remove.empty? || remove.length != add.length
          raise Refusal.new("Replace pairs each key removed with one key added; name both.",
                            code: "replace_needs_pairs", field: "add")
        end
        current.map { |key| (i = remove.index(key)) ? add[i] : key }
      when "add"
        raise Refusal.new("Name a key to add.", code: "nothing_to_add", field: "add") if add.empty?
        raise Refusal.new("Add takes keys to add, not to remove.", code: "replace_needs_pairs", field: "remove") if remove.any?

        current + add
      when "remove"
        raise Refusal.new("Name a key to remove.", code: "nothing_to_remove", field: "remove") if remove.empty?

        (current - remove) + add
      end
    end

    # [authorizers, server_leads]
    def derive_signers!(proposed)
      survivors = current & proposed
      lead_is_server = server.present? && survivors.include?(server)
      # HIS PRIORITY, NOT THE SLOT ORDER AND NOT THE CONNECTED ACCOUNT. This
      # used to sort by the connected account and then VaultState slot, which
      # asked for 9gAC (slot 3) before 3Qj4 (slot 4) and let whichever account
      # Phantom happened to have open jump the queue. The roster's priority is
      # the one order he set; the co-sign card reads the same list.
      # turf-vault checks membership, not position, so the order is ours.
      alex_seats = roster.operator_priority & survivors

      if alex_seats.empty?
        raise Refusal.new("None of your accounts stays seated through this change, so every signature " \
                          "would come from an agent key. This page always takes at least one of your " \
                          "Phantom signatures.", code: "no_human_signer")
      end

      if lead_is_server
        # Agent keys fill every slot but the last, which is always yours: a
        # rotation is never signed by agent keys alone from this page.
        agents = ([server] + (server_held & survivors)).first(required - 1)
        authorizers = agents + alex_seats.first(required - agents.length)
      else
        if mainnet?
          raise Refusal.new(
            "This change removes the server's key (or the server holds none that is seated), so the " \
            "server cannot lead it, and an operator-led rotation is refused on mainnet: Phantom alters " \
            "a transaction it is asked to pay for, so a second signature over it would not verify. " \
            "Keep the server's key in this rotation and remove it in the next.",
            code: "operator_led_mainnet"
          )
        end
        authorizers = alex_seats.first(required)
      end

      if authorizers.length < required
        raise Refusal.new(shortfall_message(lead_is_server, survivors, alex_seats),
                          code: "not_enough_signers")
      end

      [authorizers, lead_is_server]
    end

    def shortfall_message(lead_is_server, survivors, alex_seats)
      parts = []
      parts << "the server signs as #{short(server)}" if lead_is_server
      held = server_held & survivors
      parts << "the server also holds #{held.map { |k| short(k) }.join(' and ')}" if lead_is_server && held.any?
      parts << "#{alex_seats.length} of your accounts stay seated (#{alex_seats.map { |k| short(k) }.join(', ')})" if alex_seats.any?
      have = parts.any? ? parts.join("; ") : "nothing this page can collect stays seated"
      missing = (survivors - [server] - server_held - alex_seats).map { |k| short(k) }
      tail = missing.any? ? " The other staying keys (#{missing.join(', ')}) sign on no surface here: Steffon can " \
                            "set one as a window cosigner (SOLANA_COSIGNER_KEYS) for the sitting." : ""
      "This rotation needs #{required} signatures from keys that stay seated, and this page can " \
        "collect fewer: #{have}.#{tail}"
    end

    def sentence(lead_is_server, held, queue)
      server_part =
        if lead_is_server
          extra = held.any? ? " and for #{held.map { |k| short(k) }.join(' and ')}" : ""
          "The server signs for itself as #{short(server)}#{extra}. "
        else
          "Nothing is signed on the server; the first account pays the network fee. "
        end

      # The clock is the blockhash's (about 60-90 seconds from the click), unless
      # the server leads on the console's durable nonce, which never expires.
      clock =
        if lead_is_server && nonce_ready
          " There is no time limit: the transaction waits on a durable nonce until you finish."
        else
          " You have about 45 seconds from the first prompt."
        end

      phantom_part =
        case queue.length
        when 1 then "You sign once in Phantom as #{short(queue.first)}."
        when 2 then "You sign twice: first as #{short(queue[0])}, then switch Phantom to #{short(queue[1])} " \
                    "and sign again.#{clock}"
        else "You sign #{queue.length} times in Phantom, in this order: #{queue.map { |k| short(k) }.join(', ')}.#{clock}"
        end

      server_part + phantom_part
    end

    def decode(key)
      SignerIsolation.decode_base58(key)
    rescue ArgumentError
      nil
    end

    def short(key)
      key = key.to_s
      key.length > 12 ? "#{key[0, 4]}…#{key[-4, 4]}" : key
    end
  end
end
