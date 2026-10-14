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
  # `SOLANA_DURABLE_NONCE_PUBKEY` (the production nonce 2bSn…, which has no
  # other caller) is a fallback candidate, used ONLY while its on-chain
  # authority is the current server key.
  #
  # One rotation is in flight at a time (`#create_rotation` refuses a second),
  # so one nonce per server key is enough.
  class ConsoleNonce
    SEED = "turf-signer-console".freeze
    SYSTEM_PROGRAM_B58 = "11111111111111111111111111111111".freeze

    # The four answers `#status` gives.
    READY = "ready".freeze           # initialized, System-owned, authority = server
    MISSING = "missing".freeze       # no candidate is usable; `#prepare!` can create one
    NO_SERVER_KEY = "no_server_key".freeze
    UNREADABLE = "unreadable".freeze # the chain could not be read

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
      raise Refused, "This process holds no server key, so it cannot create a console nonce." unless server
      raise Refused, "The console nonce #{status[:pubkey]} is already ready." if ready?
      if status[:state] == UNREADABLE
        raise Refused, "The chain could not be read, so the console nonce was not created."
      end

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

    # ADVANCE the nonce, which voids every wire built on its current value.
    # Used by the console's reconcile to retire a broadcast that never landed
    # (a nonce wire does not lapse on its own). Server-signed, recent
    # blockhash.
    def advance!(pubkey)
      admin = Keypair.admin
      raise Refused, "The server key is not the authority of #{pubkey}." unless admin.to_base58 == server

      tx = Transaction.new
      tx.set_recent_blockhash(vault.client.get_latest_blockhash)
      tx.add_signer(admin)
      tx.add_instruction(**SystemProgram.advance_nonce_account(nonce: pubkey, authority: admin.public_key_bytes))
      vault.client.send_and_confirm(tx.serialize_base64)
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
      base.merge(state: MISSING)
    rescue StandardError => e
      Rails.logger.warn("[solana] console nonce read failed: #{Config.redact_message(e.message)}")
      base.merge(state: UNREADABLE)
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
