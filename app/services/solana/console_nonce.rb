module Solana
  # THE SIGNER CONSOLE'S DURABLE NONCE: what lets a rotation that needs two
  # Phantom signatures wait for the operator, however long he takes.
  #
  # ── WHY THE CONSOLE NEEDS ONE ──────────────────────────────────────────────
  #
  # A v0.26 `update_signers` led by the server needs the server's signature
  # plus two Phantom signatures from two accounts in one Phantom wallet, with a
  # manual account switch between them. On a recent blockhash the wire dies
  # about 60-90 seconds after it is minted. Production measured that window
  # running out twice (ptx-432 and ptx-433, "Blockhash not found"): two prompts
  # and an account switch take about 70 seconds. A nonce-anchored wire never
  # expires; it dies only when its nonce advances.
  #
  # ── WHY PHANTOM DOES NOT BREAK IT HERE ─────────────────────────────────────
  #
  # A nonce wire is recognised only while advanceNonceAccount is instruction 0,
  # and Phantom injects Lighthouse instructions into transactions it signs.
  # That killed nonce-anchored ENTRIES in the June mainnet incident, and the
  # repo then generalised it to "any Phantom-signed flow". Mainnet says
  # otherwise: Phantom injects only into a wire NO ONE HAS SIGNED YET, because
  # rewriting a partially-signed message would invalidate the signature already
  # on it. The full evidence is in docs/SOLANA.md ("Evicting a signer"):
  #
  #   * The incident's entries were Phantom-FIRST (b8970f0f): an unsigned wire.
  #   * Every unsigned create_contest since landed with 7 Lighthouse
  #     instructions around the app instruction.
  #   * The four server-PRE-SIGNED, nonce-anchored creates (the retired
  #     `prepare_onchain_contest` path, which broadcast Phantom's own returned
  #     bytes) landed as `advanceNonce | ComputeBudget | ComputeBudget |
  #     create_contest`, signers 8K81 then 7ZDJ, with no Lighthouse instruction
  #     at all. For example
  #     5BhL9AfUnukZFBzjmtHsKPzBHXnMArLLYTgsUhVr6G37C6rEwk7Swz8KpKzpHtvhi3iRBaKrUnTagFpzQNVMb2mV.
  #   * Every server-pre-signed settle, sweep, cancel and update_signers on the
  #     mainnet vault carries none either.
  #
  # The console's wire is server-signed before Phantom sees it, so it is the
  # second shape. And the console never broadcasts Phantom's bytes anyway:
  # `cosign_signatures.js` keeps only each wallet's 64-byte signature and merges
  # it onto the server's own bytes, and `#broadcast` refuses a wire whose
  # message differs from the one stored. A wallet that rewrote the message
  # would produce a signature that fails to verify, never a reordered wire.
  #
  # ── WHY THE ADDRESS IS DERIVED FROM THE SERVER KEY ─────────────────────────
  #
  # The nonce authority signs the advance, and the only key this console can
  # count on to be in a server-led rotation is the server's own (account 0).
  # So the authority IS the server key, and the address is
  # createWithSeed(server, SEED, System program): each server key has its own
  # console nonce, found without an env var. When the server key rotates
  # (8K81 -> 4S39), the new key derives a new address and the page offers to
  # create it; nothing depends on 8K81 staying the authority.
  #
  # `SOLANA_DURABLE_NONCE_PUBKEY` is a fallback candidate, used ONLY while its
  # on-chain authority is the current server key. It is UNSET on
  # turf-monster-mainnet and turf-monster-qa: the old nonce 2bSn… was closed in
  # the mainnet key rotation, so the derived nonce is the only path in both.
  # Set it only to rescue a derived address blocked by a dust transfer.
  #
  # One rotation is in flight at a time (`#create_rotation` refuses a second),
  # so one nonce per server key is enough.
  #
  # ── A WIRE THAT DOES NOT EXPIRE MUST BE KILLED ON PURPOSE ──────────────────
  #
  # turf-vault's update_signers takes only `new_signers` and pins nothing about
  # the set it replaces, so a signed rotation that never landed would re-apply
  # its old set whenever it is sent, for as long as its authorizers stay seated
  # and its nonce holds the value it was built on. Advancing the nonce is the
  # wire's only death. `#void!` does that, and the console calls it on every
  # way a nonce row ends without landing (Solana::VoidConsoleNonceJob), and
  # again, synchronously, before it builds on a value an ended row still holds.
  #
  # A SERVER-KEY CHANGE STRANDS THE OLD KEY'S NONCE: the new key is not its
  # authority and cannot advance it. So the rule is ADVANCE BEFORE THE SWITCH:
  # every ending voids at once, which leaves only a live row (inside
  # Admin::AuthoritiesController::NONCE_PENDING_AFTER of its build) or a
  # broadcast awaiting its verdict holding an unspent value. Anything else is an
  # OUTSTANDING wire (`#outstanding`): the console and the ceremony both
  # show it as a hard stop, so the key is not switched over one.
  #
  # A DUST TRANSFER TO THE DERIVED ADDRESS BLOCKS `#prepare!`: CreateAccountWithSeed
  # refuses an address that already holds lamports, and anyone can send some.
  # The status reads OCCUPIED and prepare refuses; the remedy is a nonce made by
  # hand with the server key as authority, named in SOLANA_DURABLE_NONCE_PUBKEY.
  class ConsoleNonce
    SEED = "turf-signer-console".freeze
    SYSTEM_PROGRAM_B58 = "11111111111111111111111111111111".freeze

    # The four answers `#status` gives.
    READY = "ready".freeze           # initialized, System-owned, authority = server
    MISSING = "missing".freeze       # no candidate is usable; `#prepare!` can create one
    NO_SERVER_KEY = "no_server_key".freeze
    UNREADABLE = "unreadable".freeze # the chain could not be read
    OCCUPIED = "occupied".freeze     # the derived address holds something that is not our nonce

    # What `#void!` answers.
    VOID_OUTCOMES = %i[advanced already_moved unvoidable unread].freeze

    class Refused < StandardError; end

    # createWithSeed(base, seed, System program), as base58.
    def self.address_for(base)
      base_bytes = SystemProgram.normalize(base)
      Keypair.encode_base58(
        Digest::SHA256.digest(base_bytes + SEED.b + Transaction::SYSTEM_PROGRAM_ID)
      )
    end

    # CreateAccountWithSeed (System ix 3) with the base as its own funder, so
    # the base account appears once (the web3.js encoding).
    def self.create_with_seed_instruction(funder:, new_account:, lamports:,
                                          space: SystemProgram::NONCE_ACCOUNT_LENGTH)
      base = SystemProgram.normalize(funder)
      data = [3].pack("V") + base + [SEED.bytesize].pack("Q<") + SEED.b +
             [lamports].pack("Q<") + [space].pack("Q<") + Transaction::SYSTEM_PROGRAM_ID
      {
        program_id: SystemProgram::PROGRAM_ID,
        accounts: [
          { pubkey: base, is_signer: true, is_writable: true },
          { pubkey: SystemProgram.normalize(new_account), is_signer: false, is_writable: true }
        ],
        data: data
      }
    end

    attr_reader :vault, :server

    def initialize(vault:, server: CosignPlan.admin_address, env_pubkey: ENV["SOLANA_DURABLE_NONCE_PUBKEY"])
      @vault = vault
      @server = server.presence
      @env_pubkey = env_pubkey.to_s.strip.presence
    end

    def derived_address
      server && self.class.address_for(server)
    end

    def candidates
      [derived_address, @env_pubkey].compact.uniq
    end

    # { state:, pubkey:, authority:, value:, derived: }. Never raises.
    def status
      return @status if defined?(@status)

      @status = compute_status
    end

    def ready?
      status[:state] == READY
    end

    # The `durable_nonce:` a builder takes, or nil when no nonce is ready.
    def config
      ready? ? { pubkey: status[:pubkey], authority: server } : nil
    end

    # CREATE the derived nonce: the server key funds it (rent-exempt for 80
    # bytes, about 0.0015 SOL) and is its authority. One server-signed
    # transaction, the app's own key inside the running app; nothing else
    # signs it. Refuses when a ready nonce already exists.
    def prepare!
      assert_preparable!

      admin = Keypair.admin
      raise Refused, "The server key changed while this was being prepared; reload." unless admin.to_base58 == server

      nonce = derived_address
      lamports = vault.client.get_minimum_balance_for_rent_exemption(SystemProgram::NONCE_ACCOUNT_LENGTH)
      tx = Transaction.new
      tx.set_recent_blockhash(vault.client.get_latest_blockhash)
      tx.add_signer(admin)
      tx.add_instruction(**self.class.create_with_seed_instruction(funder: admin.public_key_bytes,
                                                                  new_account: nonce, lamports: lamports))
      tx.add_instruction(**SystemProgram.initialize_nonce_account(nonce: nonce, authority: admin.public_key_bytes))
      signature = vault.client.send_and_confirm(tx.serialize_base64)
      remove_instance_variable(:@status) if defined?(@status)
      { pubkey: nonce, signature: signature }
    end

    # Raises Refused when `#prepare!` would refuse, before anything is signed.
    def assert_preparable!
      raise Refused, "This process holds no server key, so it cannot create a console nonce." unless server
      raise Refused, "The console nonce #{status[:pubkey]} is already ready." if ready?
      if status[:state] == UNREADABLE
        raise Refused, "The chain could not be read, so the console nonce was not created."
      end
      return unless status[:state] == OCCUPIED

      raise Refused, "The console nonce address #{derived_address} already holds an account that is not this " \
                     "server's nonce, so it cannot be created there. Create a nonce with this server key as its " \
                     "authority and name it in SOLANA_DURABLE_NONCE_PUBKEY."
    end

    # ADVANCE the nonce, which voids every wire built on its current value.
    # Server-signed, recent blockhash. Refuses unless the nonce's ON-CHAIN
    # authority is this process's key: the advance would fail on chain anyway,
    # after a fee.
    def advance!(pubkey)
      admin = Keypair.admin
      raise Refused, "The server key changed; reload." unless admin.to_base58 == server

      authority = read(pubkey)&.authority
      unless authority == server
        raise Refused, "#{pubkey} is not a nonce this server can advance (its authority is #{authority || 'unread'})."
      end

      tx = Transaction.new
      tx.set_recent_blockhash(vault.client.get_latest_blockhash)
      tx.add_signer(admin)
      tx.add_instruction(**SystemProgram.advance_nonce_account(nonce: pubkey, authority: admin.public_key_bytes))
      vault.client.send_and_confirm(tx.serialize_base64)
    end

    # KILL every wire built on `value` of `pubkey`, if one could still land.
    #   :already_moved — the nonce no longer holds `value` (or is gone): dead
    #   :advanced      — this call advanced it, and the re-read confirms
    #   :unvoidable    — it still holds `value` and this server is not its
    #                    authority (a server-key change); see the class note
    #   :unread        — the chain could not be read or did not confirm; retry
    # Never raises.
    def void!(pubkey:, value:)
      parsed = read(pubkey)
      return :already_moved if parsed.nil? || !parsed.initialized? || parsed.nonce != value
      return :unvoidable unless server && parsed.authority == server

      advance!(pubkey)
      after = current_value(pubkey)
      after.nil? || after == value ? :unread : :advanced
    rescue StandardError => e
      Rails.logger.warn("[solana] console nonce void failed for #{pubkey}: #{Config.redact_message(e.message)}")
      :unread
    end

    # READ-ONLY: which of `rows` (ended signer-console rows) still hold a wire
    # that could land, because their nonce still holds the built value. Each is
    # { row:, nonce:, voidable: } — voidable when this server is the nonce's
    # authority (Solana::VoidConsoleNonceJob will kill it), false when only the
    # old server key could (a server-key change). An unread nonce counts as
    # outstanding: a read that failed proves nothing dead.
    def outstanding(rows)
      rows.filter_map do |row|
        meta = row.parsed_metadata["console_nonce"].presence or next
        parsed = begin
          read(meta["pubkey"])
        rescue StandardError
          :unread
        end
        next if parsed.nil? || (parsed != :unread && (!parsed.initialized? || parsed.nonce != meta["value"]))

        { row: row, nonce: meta, voidable: parsed != :unread && server.present? && parsed.authority == server }
      end
    end

    # The value stored in `pubkey` now, or nil when it cannot be read.
    def current_value(pubkey)
      parsed = read(pubkey)
      parsed&.initialized? ? parsed.nonce : nil
    end

    private

    def compute_status
      base = { pubkey: derived_address, authority: nil, value: nil, derived: derived_address }
      return base.merge(state: NO_SERVER_KEY) unless server

      candidates.each do |pubkey|
        parsed = read(pubkey)
        next unless parsed&.initialized? && parsed.authority == server

        return base.merge(state: READY, pubkey: pubkey, authority: parsed.authority, value: parsed.nonce)
      end
      base.merge(state: derived_occupied? ? OCCUPIED : MISSING)
    rescue StandardError => e
      Rails.logger.warn("[solana] console nonce read failed: #{Config.redact_message(e.message)}")
      base.merge(state: UNREADABLE)
    end

    # The derived address holds an account (dust, or a nonce of another
    # authority), so CreateAccountWithSeed would refuse it.
    def derived_occupied?
      vault.client.get_account_info(derived_address)&.dig("value").present?
    end

    # The parsed nonce account, or nil when it does not exist or is not a
    # System-owned nonce account. Raises when the chain cannot be read.
    def read(pubkey)
      value = vault.client.get_account_info(pubkey)&.dig("value")
      return nil unless value
      return nil if value["owner"].present? && value["owner"] != SYSTEM_PROGRAM_B58

      data = value.dig("data", 0)
      return nil if data.blank?

      bytes = Base64.decode64(data).b
      return nil if bytes.bytesize < SystemProgram::NONCE_ACCOUNT_LENGTH

      NonceAccount.parse(bytes)
    end
  end
end
