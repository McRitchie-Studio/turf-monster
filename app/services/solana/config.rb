module Solana
  module Config
    # OPSEC-012: `SOLANA_PROGRAM_ID` required in production. Previously fell
    # back to the orphaned `7Hy8…r2J` (which we no longer control on devnet
    # and doesn't exist on mainnet). A missing env var would have silently
    # routed every TX to a non-existent program — or worse, to whatever an
    # attacker might deploy at that address on mainnet. Dev/test default to
    # the current devnet program ID; prod must set it explicitly.
    PROGRAM_ID = if Rails.env.production?
      ENV.fetch("SOLANA_PROGRAM_ID") { raise "SOLANA_PROGRAM_ID required in production (see OPSEC-012)" }
    else
      ENV.fetch("SOLANA_PROGRAM_ID", "EQGFJAcABtDb6VXtiijTjZ6cE2UqdvhnqJvoharJbpMJ")
    end

    # OPSEC-012's sibling, part two: `SOLANA_RPC_URL` required in production.
    #
    # This was the last fail-open Solana var — `ENV.fetch("SOLANA_RPC_URL",
    # "https://api.devnet.solana.com")`. The bad combination is
    # NETWORK=mainnet-beta with the RPC unset: PROGRAM_ID and the mints resolve
    # to MAINNET values and are then pointed at a DEVNET endpoint. Balances read
    # $0.00 against ATAs that exist on the other cluster, and anything submitted
    # lands on devnet against a program ID that does not exist there.
    #
    # IS THIS REDUNDANT WITH OPSEC-039? No — it is additive, on three counts.
    # config/initializers/solana_network_alignment.rb does compare genesis
    # hashes and does catch that exact pair, but only when it runs and only when
    # the RPC answers:
    #   1. It `rescue Solana::Client::RpcError` -> warn -> CONTINUES BOOT. The
    #      client wraps Net::OpenTimeout / Net::ReadTimeout / ECONNRESET into
    #      RpcError after its retries, and rate limits arrive the same way, so
    #      an unreachable or throttled endpoint (which the public devnet URL
    #      becomes under load) silences the one check meant to catch this.
    #   2. An unknown NETWORK has no canonical genesis, so the guard logs
    #      "skipping alignment check" and boots.
    #   3. `SOLANA_SKIP_NETWORK_CHECK=true` disables it wholesale — set during
    #      incident response and forgotten, it leaves nothing behind it.
    # And when it does fire it fires from `after_initialize`, AFTER eager load,
    # as a genesis-hash diff whose remediation line guesses at the variable.
    # This raise fires during eager load and names it.
    #
    # Dev/test keep the devnet default byte-identical, so nothing local changes.
    # Both deployed apps already set it (turf-monster-mainnet -> a Helius
    # mainnet endpoint, turf-monster-qa -> api.devnet.solana.com), so this
    # closes a hole rather than changing behaviour — including at slug-compile
    # time, where the production eager load evaluates these constants (see
    # config/initializers/solana_idl_verification.rb).
    RPC_URL = if Rails.env.production?
      ENV.fetch("SOLANA_RPC_URL") { raise "SOLANA_RPC_URL required in production (see OPSEC-012)" }
    else
      ENV.fetch("SOLANA_RPC_URL", "https://api.devnet.solana.com")
    end

    # OPSEC-012's sibling: `SOLANA_NETWORK` required in production.
    #
    # This used to be `ENV.fetch("SOLANA_NETWORK", "devnet")`, which FAILED OPEN
    # on absence. A garbage value fails closed (it is not "mainnet-beta", so the
    # devnet-only guards below and in the controllers all refuse), but an UNSET
    # var silently resolved to "devnet" on a mainnet app.
    #
    # WHAT THAT ACTUALLY REACHED — corrected 2026-08-20. The first version of
    # this comment claimed an unset var would have silently selected the DEVNET
    # MINTS on a mainnet app, citing the §8 footgun documented below. The
    # MECHANISM is real (USDC_MINT / USDT_MINT key their DEFAULTS on NETWORK)
    # but that outcome was NOT REACHABLE: `turf-monster-mainnet` sets
    # SOLANA_USDC_MINT and SOLANA_USDT_MINT explicitly, and the env override
    # always wins, so it needed THREE unset vars, not one. The claim was written
    # without reading the live config that disproves it. It is corrected here
    # rather than quietly dropped, because a comment left standing gets cited as
    # established history.
    #
    # The honest case is IDL_PATH and LEGIBILITY. NETWORK also keys IDL_PATH
    # (below), so an unset var on the mainnet app selects the DEVNET IDL, whose
    # SHA256 is not in that app's EXPECTED_IDL_HASH. The boot is then refused —
    # by the OPSEC-014 guard as an opaque hash diff, or by the OPSEC-039
    # alignment guard as a genesis diff whose remediation line names the WRONG
    # variable ("likely SOLANA_RPC_URL"). Both are `after_initialize`; this
    # raise fires during EAGER LOAD, before either of them, so the operator
    # reads the name of the variable instead of two hashes.
    #
    # Next in line behind that: `Solana::Config.devnet?` reads this constant, so
    # an unset var re-arms the OPSEC-020 fund guards — reachable only once the
    # IDL guard ahead of it is bypassed (BYPASS_IDL_CHECK, a documented escape
    # hatch), which is exactly the situation in which nobody wants a second
    # silent default.
    #
    # Dev/test keep the devnet default byte-identical, so nothing local changes.
    NETWORK = if Rails.env.production?
      ENV.fetch("SOLANA_NETWORK") { raise "SOLANA_NETWORK required in production (see OPSEC-012)" }
    else
      ENV.fetch("SOLANA_NETWORK", "devnet")
    end

    # USDC / USDT mints.
    #
    # The mainnet launch surfaced a silent-default footgun (§8): these used to
    # default UNCONDITIONALLY to the devnet test mints, so a mainnet app that
    # forgot SOLANA_USDC_MINT / SOLANA_USDT_MINT would read balances against the
    # wrong ATA ($0.00 everywhere) and derive op-rev PDAs / entry source ATAs
    # against a mint that doesn't exist on mainnet. The env override always wins;
    # only the DEFAULT is now network-keyed so a future mainnet app can't boot on
    # devnet mints by omission.
    #   - mainnet-beta -> Circle USDC / Tether USDT canonical mints
    #   - anything else (devnet/localnet/test) -> the existing devnet test mints
    #     (created via `spl-token create-token --decimals 6`) — byte-identical to
    #     the prior unconditional default, so dev/test behavior is unchanged.
    #
    # Ultimate source of truth is the on-chain VaultState `accepted_currencies`
    # slots 0/1 (see Solana::Vault#read_vault_state). The `solana:preflight` rake
    # asserts these env/default values match the vault before serving traffic.
    DEVNET_USDC_MINT  = "222Dcu2RgAXE3T8A4mGSG3kQyXaNjqePx7vva1RdWBN9"
    DEVNET_USDT_MINT  = "9mxkN8KaVA8FFgDE2LEsn2UbYLPG8Xg9bf4V9MYYi8Ne"
    MAINNET_USDC_MINT = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v" # Circle USDC
    MAINNET_USDT_MINT = "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB" # Tether USDT

    USDC_MINT = ENV.fetch("SOLANA_USDC_MINT") do
      NETWORK == "mainnet-beta" ? MAINNET_USDC_MINT : DEVNET_USDC_MINT
    end
    USDT_MINT = ENV.fetch("SOLANA_USDT_MINT") do
      NETWORK == "mainnet-beta" ? MAINNET_USDT_MINT : DEVNET_USDT_MINT
    end

    # Admin keypair path for signing settlement transactions
    ADMIN_KEYPAIR_PATH = ENV.fetch("SOLANA_ADMIN_KEYPAIR", File.expand_path("~/.config/solana/id.json"))

    # Multisig signers (base58 public keys). Default = the rotated 2-of-3 set
    # (post leaked-Alex-Bot rotation 2026-06-02): new Alex Bot 8K81…, cosigner
    # 7ZDJ…, Mason CytJ…. These are PUBLIC keys and are overridden by the
    # SOLANA_MULTISIG_SIGNERS env var (and authoritatively by VaultState.signers
    # on-chain) in every deployed environment — the literal is a fallback only.
    MULTISIG_SIGNERS = ENV.fetch("SOLANA_MULTISIG_SIGNERS",
      "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd,7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr,CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR"
    ).split(",")
    MULTISIG_THRESHOLD = ENV.fetch("SOLANA_MULTISIG_THRESHOLD", "2").to_i

    # Default cosigner for partially-signed treasury TXs (Alex Human — signs via Phantom)
    MULTISIG_COSIGNER = ENV.fetch("SOLANA_MULTISIG_COSIGNER", "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr")

    # turf-vault v0.15.0+: the ONLY wallet permitted to call `initialize` on
    # mainnet builds (per `state.rs::INIT_AUTHORITY`). Today this is the same
    # key as MULTISIG_COSIGNER (Alex's Phantom), but it's kept separate so a
    # future rotation of either role doesn't silently move the other.
    INIT_AUTHORITY = ENV.fetch("SOLANA_INIT_AUTHORITY", "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr")

    DECIMALS = 6

    # IDL hash pinning (audit Tier 3 #22). Catches drift between the Rails
    # app's expected program shape and what's actually deployed on-chain.
    # Workflow:
    #   1. Operator runs `bin/rails solana:verify_idl` (or `anchor idl fetch`)
    #      to download the deployed IDL into config/turf_vault.idl.json
    #   2. Operator runs `bin/rails solana:idl_hash` to print the SHA256
    #   3. Set EXPECTED_IDL_HASH below (or in env) to that value
    #   4. On every boot (production only), the initializer compares the
    #      committed IDL's hash against EXPECTED_IDL_HASH. Mismatch raises.
    #
    # IDL_PATH points at the committed IDL JSON. The file is hand-maintained
    # — updated when turf_vault deploys a new version.
    #
    # Network-keyed (mainnet launch): the devnet and mainnet IDLs are
    # byte-identical EXCEPT the `address` field (the program ID), which makes
    # their SHA256 differ. Each cluster therefore commits its own IDL file and
    # pins its own EXPECTED_IDL_HASH per Heroku app. Selection is by NETWORK so
    # a single source tree boots correctly on either cluster:
    #   - mainnet-beta -> config/turf_vault.mainnet.idl.json (address DaFv…, e13ffd11…)
    #   - anything else (devnet/localnet) -> config/turf_vault.idl.json (address EQGF…, c2acccaa…)
    # (hashes churn per turf-vault rev — `bin/rails solana:idl_hash` for the live value)
    # The devnet branch is byte-identical to the prior unconditional path, so
    # the live devnet-prod app's verify_idl!/precompile behavior is unchanged.
    IDL_PATH = if NETWORK == "mainnet-beta"
      Rails.root.join("config", "turf_vault.mainnet.idl.json")
    else
      Rails.root.join("config", "turf_vault.idl.json")
    end

    # Accepted IDL hash allow-list (audit OPSEC-014), comma-separated. A deploy
    # that bumps the IDL widens this to "<old>,<new>" so BOTH the outgoing and
    # incoming slugs verify across the release boundary, then tightens back to
    # "<new>" — no unverified window (bin/deploy automates this). A single hash
    # is just a one-element set. Empty string = unset (dev default; required in
    # production). Parse via expected_idl_hashes / idl_hash_acceptable?.
    EXPECTED_IDL_HASH = ENV.fetch("EXPECTED_IDL_HASH", "")

    def self.devnet?
      NETWORK == "devnet"
    end

    def self.mainnet?
      NETWORK == "mainnet-beta"
    end

    def self.dollars_to_lamports(dollars)
      (dollars * 10**DECIMALS).to_i
    end

    def self.lamports_to_dollars(lamports)
      lamports.to_f / 10**DECIMALS
    end

    # SHA256 hex digest of the committed IDL file. Returns nil if the file
    # is missing (which is the case until the operator pulls it once).
    def self.idl_hash
      return nil unless File.exist?(IDL_PATH)
      Digest::SHA256.hexdigest(File.read(IDL_PATH))
    end

    # Parsed EXPECTED_IDL_HASH allow-list: comma-split, trimmed, blanks dropped.
    # "<a>, <b> ,," => ["<a>", "<b>"]; "" => []. Takes the raw string (defaults
    # to the env-backed constant) so the parsing is unit-testable without ENV
    # mutation.
    def self.expected_idl_hashes(raw = EXPECTED_IDL_HASH)
      raw.to_s.split(",").map(&:strip).reject(&:blank?)
    end

    # True when `hash` is a member of the accepted set. The single comparison
    # primitive shared by verify_idl!, the solana:health / solana:preflight
    # rakes, and (mirrored in bash) bin/deploy's pre-flight — so the allow-list
    # semantics live in exactly one place.
    def self.idl_hash_acceptable?(hash)
      return false if hash.blank?
      expected_idl_hashes.include?(hash)
    end

    # Version string from the committed IDL's metadata (e.g. "0.19.0") — the
    # turf_vault version the Rails app is pinned to. The IDL is re-pinned on
    # every turf-vault deploy (see docs/SOLANA.md "Post-deploy IDL re-pin"),
    # so this tracks the deployed program without a hardcoded constant.
    # Returns nil if the IDL is missing or unparseable.
    def self.idl_version
      return nil unless File.exist?(IDL_PATH)
      JSON.parse(File.read(IDL_PATH)).dig("metadata", "version")
    rescue JSON::ParserError
      nil
    end

    # Raises Solana::Config::IdlMismatchError if the committed IDL's hash
    # doesn't match EXPECTED_IDL_HASH.
    #
    # OPSEC-014: in production, BOTH EXPECTED_IDL_HASH being set AND the IDL
    # file being present are required — fails closed. In dev/test we still
    # short-circuit on blank/missing because local iteration is allowed
    # against an older IDL.
    def self.verify_idl!
      # OPSEC-014 emergency bypass. Lets ops break out of a deploy-time IDL
      # skew (e.g. when EXPECTED_IDL_HASH, the committed IDL file, and the
      # freshly-built IDL have all diverged across turf-vault versions).
      # Set BYPASS_IDL_CHECK=true on Heroku, deploy the new IDL, then run
      # `heroku config:set EXPECTED_IDL_HASH=<new>` + `heroku config:unset
      # BYPASS_IDL_CHECK` to restore verified state. Logs loud so the
      # unverified window is visible in production logs.
      if ENV["BYPASS_IDL_CHECK"].to_s.downcase == "true"
        Rails.logger.warn "[opsec-014] IDL verification BYPASSED via BYPASS_IDL_CHECK=true — production is running unverified. Unset BYPASS_IDL_CHECK after the next successful release."
        return
      end

      if expected_idl_hashes.empty?
        raise IdlMismatchError, "EXPECTED_IDL_HASH required in production (see OPSEC-014)" if Rails.env.production?
        return
      end

      actual = idl_hash
      if actual.nil?
        raise IdlMismatchError, "#{IDL_PATH} not found — IDL must be committed in production (see OPSEC-014)" if Rails.env.production?
        return
      end

      return if idl_hash_acceptable?(actual)

      raise IdlMismatchError, <<~MSG
        IDL hash not in the accepted set — refusing to boot.

        Accepted: #{expected_idl_hashes.join(", ")}
        Got:      #{actual}

        Either #{IDL_PATH} drifted from the deployed program, or someone
        tampered with it. Re-pull the IDL with:
          anchor idl fetch #{PROGRAM_ID} --provider.cluster #{NETWORK} \\
            > #{IDL_PATH}
          bin/rails solana:idl_hash  # then set EXPECTED_IDL_HASH

        Normal IDL bumps are automated by `bin/deploy` — it widens
        EXPECTED_IDL_HASH to "<old>,<new>" across the release, then tightens to
        "<new>", so there's no unverified window. Manual break-glass: `heroku
        config:set BYPASS_IDL_CHECK=true`, deploy, set EXPECTED_IDL_HASH, then
        `heroku config:unset BYPASS_IDL_CHECK`. Don't leave BYPASS on.
        In dev/test: `unset EXPECTED_IDL_HASH`. Don't ship to prod without a pin.
      MSG
    end

    class IdlMismatchError < StandardError; end
  end
end
