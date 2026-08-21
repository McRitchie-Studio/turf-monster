# solana:preflight — internal-consistency gate for the prod Solana config.
#
# Complement to `solana:health` (which validates the RPC stack — genesis hash,
# program-exists, IDL-pin). `preflight` instead asserts that the *configuration
# this app booted with* is internally consistent and agrees with the on-chain
# vault:
#
#   1. Required env vars are all present (no silent devnet defaults on a mainnet
#      app — the §8 launch footgun).
#   2. The committed IDL hash matches EXPECTED_IDL_HASH.
#   3. The configured USDC/USDT mints MATCH the on-chain VaultState
#      `accepted_currencies` slots 0/1 — the ultimate source of truth.
#
# Exits non-zero with a per-check report on any mismatch. This single task
# would have caught all three §8 gaps (unset mints, IDL skew, vault drift).
#
# Run before flipping traffic to a new app / cluster:
#   heroku run -a turf-monster-mainnet bin/rails solana:preflight
namespace :solana do
  desc "Assert prod Solana config is internally consistent (env + IDL + on-chain vault mints)"
  task preflight: :environment do
    exit_code = 0
    pass = ->(msg) { puts "  ✓ #{msg}" }
    fail = ->(msg) { puts "  ✗ #{msg}"; exit_code = 1 }
    info = ->(msg) { puts "  · #{msg}" }

    puts "=== Solana preflight (config consistency) ==="
    puts "  NETWORK    = #{Solana::Config::NETWORK}"
    puts "  RPC_URL    = #{Solana::Config.redact_rpc_url(Solana::Config::RPC_URL)}"
    puts "  PROGRAM_ID = #{Solana::Config::PROGRAM_ID}"
    puts "  USDC_MINT  = #{Solana::Config::USDC_MINT}"
    puts "  USDT_MINT  = #{Solana::Config::USDT_MINT}"
    puts

    # --- 1. Required env vars present ---------------------------------------
    # On a fresh mainnet app these MUST be set explicitly.
    #
    # The mint defaults are network-keyed, but do NOT read that as "omission is
    # safe" — this comment used to, and it was wrong. A network-keyed default is
    # only as trustworthy as the key it is keyed on, and SOLANA_NETWORK was
    # itself a defaulting env var: unset on a mainnet app it resolved to
    # "devnet", and the whole scheme resolved with it. That is why
    # SOLANA_NETWORK, SOLANA_RPC_URL and SOLANA_PROGRAM_ID now RAISE in
    # production instead of defaulting (OPSEC-012 and siblings).
    #
    # This check stays regardless: on a prod cluster every value should be set
    # deliberately rather than leaning on a default.
    puts "1. Required env vars"
    required = %w[
      SOLANA_NETWORK
      SOLANA_RPC_URL
      SOLANA_PROGRAM_ID
      EXPECTED_IDL_HASH
      SOLANA_USDC_MINT
      SOLANA_USDT_MINT
      SOLANA_ADMIN_KEY
    ]
    required.each do |var|
      if ENV[var].to_s.strip.empty?
        fail.("#{var} is unset")
      else
        # Don't echo secrets; just confirm presence. Only the RPC URL goes
        # through redact_rpc_url — it is a URL redactor, and a bare base58
        # program ID / mint would come back as "***".
        shown = case var
        when "SOLANA_ADMIN_KEY" then "(set)"
        when "SOLANA_RPC_URL"   then Solana::Config.redact_rpc_url(ENV[var])
        else ENV[var]
        end
        pass.("#{var} present — #{shown}")
      end
    end
    puts

    # --- 2. Committed IDL hash matches EXPECTED_IDL_HASH --------------------
    puts "2. IDL hash pin"
    expected_hash = Solana::Config::EXPECTED_IDL_HASH
    committed_hash = Solana::Config.idl_hash
    if expected_hash.blank?
      fail.("EXPECTED_IDL_HASH is blank — no pin to verify against")
    elsif committed_hash.nil?
      fail.("committed IDL not found at #{Solana::Config::IDL_PATH}")
    elsif Solana::Config.idl_hash_acceptable?(committed_hash)
      pass.("committed IDL (#{Solana::Config::IDL_PATH.basename}) is in the EXPECTED_IDL_HASH set")
    else
      fail.("committed IDL hash #{committed_hash} not in EXPECTED_IDL_HASH set #{Solana::Config.expected_idl_hashes.join(', ')}")
    end
    puts

    # --- 3. Configured mints match the on-chain VaultState -----------------
    # The ultimate source of truth: slots 0/1 of accepted_currencies. A mint
    # that's configured here but absent from / different in the vault means
    # balance reads and op-rev/source-ATA derivation point at the wrong place.
    puts "3. On-chain VaultState accepted_currencies (slots 0/1)"
    begin
      vault = Solana::Vault.new.read_vault_state
      if vault.nil?
        fail.("VaultState account not found — vault uninitialized at this PROGRAM_ID/NETWORK")
      else
        info.("vault PDA #{vault[:pda]}")

        checks = {
          "USDC (slot 0)" => [Solana::Config::USDC_MINT, vault[:usdc_mint]],
          "USDT (slot 1)" => [Solana::Config::USDT_MINT, vault[:usdt_mint]]
        }
        checks.each do |label, (configured, onchain)|
          if onchain.nil?
            fail.("#{label}: vault slot empty/unregistered — configured #{configured}")
          elsif configured == onchain
            pass.("#{label}: configured mint matches vault — #{onchain}")
          else
            fail.("#{label}: configured #{configured} ≠ vault #{onchain}")
          end
        end

        # Surface paused state — not a hard fail, but a flip into a paused
        # vault is almost never intentional at preflight time.
        info.("vault paused = #{vault[:paused]}")
      end
    rescue Solana::Client::RpcError => e
      # redact_message, not a bare truncation: this rescue also catches the
      # client CONSTRUCTOR's Solana::Client::InsecureRpcUrlError (and
      # URI::InvalidURIError), both of which interpolate the whole credentialed
      # endpoint into their own message. Truncating at 160 chars is not
      # redaction — the key sits at the front of the string. Same defect, same
      # rotation path, as the one fixed in solana:health.
      fail.("VaultState read failed (RPC): #{Solana::Config.redact_message(e.message).truncate(160)}")
    rescue StandardError => e
      fail.("VaultState read failed: #{e.class}: #{Solana::Config.redact_message(e.message).truncate(160)}")
    end

    puts
    if exit_code.zero?
      puts "OK — Solana config is internally consistent on #{Solana::Config::NETWORK}."
    else
      puts "FAIL — fix the above before serving traffic. (See §8 launch footguns.)"
    end
    exit exit_code
  end
end
