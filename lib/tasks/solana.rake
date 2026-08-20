# OPSEC-013: any rake task that mutates on-chain state requires explicit
# opt-in in production. Prevents an accidental `bin/rails solana:init_vault
# FORCE_CLOSE=true` on a production console from bricking the live vault.
# The opt-in is intentionally clunky — CONFIRM_PROD=yes — so it can't be
# tab-completed or muscle-memoried.
def require_solana_prod_confirmation!(task_name)
  return unless Rails.env.production?
  return if ENV["CONFIRM_PROD"] == "yes"
  abort <<~MSG
    Refusing to run `#{task_name}` in production without explicit confirmation.

    This task mutates on-chain state. To run it in production, re-invoke with:
      CONFIRM_PROD=yes bin/rails #{task_name} ...

    See OPSEC-013 in the pre-prod audit doc.
  MSG
end

namespace :solana do
  desc "Initialize vault on Devnet (run once per program deploy)"
  task init_vault: :environment do
    vault = Solana::Vault.new
    admin = Solana::Keypair.admin

    puts "Admin address: #{admin.to_base58}"
    puts "Program ID: #{Solana::Config::PROGRAM_ID}"
    puts "Network: #{Solana::Config::NETWORK}"

    balance = vault.client.get_balance(admin.to_base58)
    puts "Admin SOL balance: #{balance.dig('value').to_f / 1_000_000_000}"

    puts "\nVault PDAs:"
    vault_pda, vault_bump = vault.vault_state_pda
    puts "  vault_state:        #{Solana::Keypair.encode_base58(vault_pda)} (bump: #{vault_bump})"

    payout_op_rev, payout_bump = vault.op_rev_ata_pda(Solana::Config::USDC_MINT)
    second_op_rev, second_bump = vault.op_rev_ata_pda(Solana::Config::USDT_MINT)
    puts "  op_rev USDC (slot 0): #{Solana::Keypair.encode_base58(payout_op_rev)} (bump: #{payout_bump})"
    puts "  op_rev USDT (slot 1): #{Solana::Keypair.encode_base58(second_op_rev)} (bump: #{second_bump})"

    puts "\nMints:"
    puts "  USDC: #{Solana::Config::USDC_MINT}"
    puts "  USDT: #{Solana::Config::USDT_MINT}"

    # v0.16: force_close_vault is gone (the instruction was dropped). When
    # the on-chain VaultState layout changes, the recovery path is now to
    # redeploy the program (devnet teardown is acceptable per spec §1).

    if ENV["INIT"] == "true"
      require_solana_prod_confirmation!("solana:init_vault INIT=true")

      signers_str = ENV["SIGNERS"]
      unless signers_str
        puts "\nERROR: SIGNERS env var required (comma-separated base58 signer addresses)"
        puts "Usage: bin/rails solana:init_vault INIT=true SIGNERS=addr1,addr2,addr3 THRESHOLD=2 TREASURY=<squads_vault_pda>"
        exit 1
      end

      signer_list = signers_str.split(",").map(&:strip)
      unless signer_list.length == 3
        puts "\nERROR: Exactly 3 signers required, got #{signer_list.length}"
        exit 1
      end

      threshold = (ENV["THRESHOLD"] || "2").to_i
      treasury  = ENV["TREASURY"].presence || ENV["SOLANA_SQUADS_VAULT_PDA"].presence ||
                  "BW13kgfiG2koFn3WRkte21NW9TFygsD1ge2fNJdjH6kC"

      puts "\nInitializing vault..."
      signer_list.each_with_index { |s, i| puts "  Signer #{i + 1}: #{s}" }
      puts "  Threshold:          #{threshold}"
      puts "  Treasury authority: #{treasury}"
      result = vault.initialize_vault(
        signers:            signer_list,
        threshold:          threshold,
        treasury_authority: treasury
      )
      puts "Vault initialized!"
      puts "  Signature: #{result[:signature]}"
      puts "  Vault PDA: #{result[:vault_pda]}"
    else
      puts "\nTo initialize, run: bin/rails solana:init_vault INIT=true SIGNERS=addr1,addr2,addr3 THRESHOLD=2 TREASURY=<squads_vault_pda>"
      puts "(v0.16: force_close_vault is gone — redeploy the program to teardown devnet state.)"
    end
  end

  desc "Airdrop SOL to admin wallet"
  task airdrop: :environment do
    vault = Solana::Vault.new
    admin = Solana::Keypair.admin
    amount = (ENV["SOL"] || "2").to_i

    puts "Airdropping #{amount} SOL to #{admin.to_base58}..."
    sig = vault.client.request_airdrop(admin.to_base58, amount * 1_000_000_000)
    puts "Signature: #{sig}"

    sleep 2
    balance = vault.client.get_balance(admin.to_base58)
    puts "New balance: #{balance.dig('value').to_f / 1_000_000_000} SOL"
  end

  desc "Check onchain state for a user (v0.16: UserAccount stats + ATA balance)"
  task check_balance: :environment do
    address = ENV["ADDRESS"]
    unless address
      puts "Usage: bin/rails solana:check_balance ADDRESS=<solana_address>"
      exit 1
    end

    vault = Solana::Vault.new
    result = vault.sync_balance(address)

    if result
      puts "On-chain state for #{address}:"
      puts "  USDC ATA balance: $#{result[:balance_dollars]}"
      puts "  Username:         #{result[:username]}"
      puts "  Seeds:            #{result[:seeds]}"
      puts "  Entries:          #{result[:entries]}"
      puts "  Wins:             #{result[:wins]}"
      puts "  Cashes:           #{result[:cashes]}"
      puts "  Total won:        $#{result[:total_won_dollars]}"
    else
      puts "No UserAccount found for #{address}"
    end
  end

  desc "Generate a test keypair"
  task generate_keypair: :environment do
    keypair = Solana::Keypair.generate
    puts "Address: #{keypair.to_base58}"
    puts "Encrypted key: #{keypair.encrypt}"
    puts "\nStore the encrypted key in user.encrypted_solana_private_key"
  end

  desc "Reconcile DB balances against onchain state"
  task reconcile: :environment do
    reconciler = Solana::Reconciler.new
    result = reconciler.reconcile_all

    puts "Checked #{result[:users_checked]} users"
    if result[:discrepancies].empty?
      puts "No discrepancies found."
    else
      puts "#{result[:discrepancies].size} discrepancies:"
      result[:discrepancies].each do |d|
        puts "  [#{d[:type]}] User #{d[:user_id]} (#{d[:user_name]}): #{d.except(:type, :user_id, :user_name).to_json}"
      end
    end
  end

  desc "Reconcile a specific contest"
  task reconcile_contest: :environment do
    slug = ENV["CONTEST"]
    unless slug
      puts "Usage: bin/rails solana:reconcile_contest CONTEST=<slug>"
      exit 1
    end

    contest = Contest.find_by(slug: slug)
    unless contest
      puts "Contest not found: #{slug}"
      exit 1
    end

    reconciler = Solana::Reconciler.new
    result = reconciler.reconcile_contest(contest)

    if result
      puts "Onchain contest state:"
      puts "  Entry fee (slot 0 USDC): #{result[:entry_fee]} lamports"
      puts "  Max entries:             #{result[:max_entries]}"
      puts "  Current entries:         #{result[:current_entries]}"
      puts "  Entry fees collected:    #{result[:entry_fees]} lamports (USDC slot 0)"
      puts "  Prize pool:              #{result[:prize_pool]} lamports"
    else
      puts "No onchain data found"
    end

    if reconciler.discrepancies.any?
      puts "\nDiscrepancies:"
      reconciler.discrepancies.each { |d| puts "  #{d.to_json}" }
    end
  end

  desc "Mint test USDC to admin wallet (Devnet only)"
  task mint_usdc: :environment do
    # OPSEC-020 / OPSEC-013: hard-disable on production. This task uses
    # mint authority that only the operator holds on devnet test mints —
    # on real mainnet USDC the call would fail, but defense-in-depth.
    # AppFlags.live_production? (not Rails.env.production?) so a QA app — which
    # boots as Rails production but is a devnet review target — can still mint.
    abort "solana:mint_usdc is devnet-only (see OPSEC-020)" if AppFlags.live_production?

    amount_dollars = (ENV["AMOUNT"] || "100").to_f
    amount_lamports = Solana::Config.dollars_to_lamports(amount_dollars)

    vault = Solana::Vault.new
    admin = Solana::Keypair.admin

    puts "Minting #{amount_dollars} USDC to admin (#{admin.to_base58})..."

    # Ensure admin ATA exists
    ata_result = vault.ensure_ata(admin.to_base58, mint: Solana::Config::USDC_MINT)
    if ata_result[:created]
      puts "  Created admin USDC ATA: #{ata_result[:ata]} (tx: #{ata_result[:signature]})"
    else
      puts "  Admin USDC ATA exists: #{ata_result[:ata]}"
    end

    # Mint tokens
    result = vault.mint_spl(amount_lamports, mint: Solana::Config::USDC_MINT)
    puts "  Minted #{amount_dollars} USDC"
    puts "  Signature: #{result[:signature]}"
    puts "  Destination: #{result[:destination]}"
  end

  desc "Show admin SOL + SPL token balances"
  task check_admin_balance: :environment do
    vault = Solana::Vault.new
    admin = Solana::Keypair.admin

    puts "Admin wallet: #{admin.to_base58}"
    puts ""

    balances = vault.fetch_wallet_balances(admin.to_base58)

    puts "SOL:  #{balances[:sol]}"
    puts "USDC: #{balances[:usdc]}" if balances[:usdc]
    puts "USDT: #{balances[:usdt]}" if balances[:usdt]

    if balances[:tokens].any?
      puts ""
      puts "All token accounts:"
      balances[:tokens].each do |mint, amount|
        label = case mint
                when Solana::Config::USDC_MINT then " (USDC)"
                when Solana::Config::USDT_MINT then " (USDT)"
                else ""
                end
        puts "  #{mint}#{label}: #{amount}"
      end
    end
  end

  desc "Fund all user wallets with SOL (airdrop + admin transfer fallback)"
  task fund_wallets: :environment do
    vault = Solana::Vault.new
    admin = Solana::Keypair.admin
    min_sol = (ENV["MIN_SOL"] || "0.1").to_f
    airdrop_sol = (ENV["SOL"] || "1").to_f

    # Collect wallets: admin + all users with solana addresses
    wallets = [{ name: "Admin", address: admin.to_base58 }]
    User.where.not(solana_address: nil).find_each do |u|
      wallets << { name: u.name, address: u.solana_address }
    end

    puts "Checking #{wallets.size} wallets (min: #{min_sol} SOL, airdrop: #{airdrop_sol} SOL)\n\n"

    needs_funding = []
    wallets.each do |w|
      begin
        result = vault.client.get_balance(w[:address])
        sol = result.dig("value").to_f / 1_000_000_000
        status = sol >= min_sol ? "OK" : "LOW"
        puts "  %-20s %s  %.4f SOL  %s" % [w[:name], w[:address], sol, status]
        needs_funding << w if sol < min_sol
      rescue => e
        puts "  %-20s %s  ERROR: %s" % [w[:name], w[:address], e.message]
        needs_funding << w
      end
    end

    if needs_funding.empty?
      puts "\nAll wallets funded."
      next
    end

    puts "\n#{needs_funding.size} wallet(s) need funding...\n\n"

    needs_funding.each do |w|
      # Try airdrop first
      begin
        puts "  Airdropping #{airdrop_sol} SOL to #{w[:name]} (#{w[:address]})..."
        sig = vault.client.request_airdrop(w[:address], (airdrop_sol * 1_000_000_000).to_i)
        puts "    Success: #{sig}"
        sleep 1
      rescue => e
        if e.message.include?("airdrop") || e.message.include?("rate")
          puts "    Airdrop rate-limited, transferring from admin..."
          begin
            transfer_lamports = (airdrop_sol * 1_000_000_000).to_i
            tx = Solana::Transaction.new
            tx.set_recent_blockhash(vault.client.get_latest_blockhash)
            tx.add_signer(admin)
            tx.add_instruction(
              program_id: Solana::Transaction::SYSTEM_PROGRAM_ID,
              accounts: [
                { pubkey: admin.public_key_bytes, is_signer: true, is_writable: true },
                { pubkey: Solana::Keypair.decode_base58(w[:address]), is_signer: false, is_writable: true }
              ],
              data: [2, 0, 0, 0].pack("C4") + [transfer_lamports].pack("Q<")
            )
            sig = vault.client.send_and_confirm(tx.serialize_base64)
            puts "    Transferred from admin: #{sig}"
          rescue => te
            puts "    Transfer failed: #{te.message}"
          end
        else
          puts "    Failed: #{e.message}"
        end
      end
    end

    puts "\nFinal balances:"
    wallets.each do |w|
      begin
        result = vault.client.get_balance(w[:address])
        sol = result.dig("value").to_f / 1_000_000_000
        puts "  %-20s %.4f SOL" % [w[:name], sol]
      rescue => e
        puts "  %-20s ERROR" % [w[:name]]
      end
    end
  end

  # `solana:migrate_accounts` task removed alongside turf-vault v0.15.1
  # (prelaunch audit C1) — the underlying migrate_user_account instruction
  # is gone. If a UserAccount ever appears at an unexpected size in the
  # future, Solana::Vault#ensure_user_account raises with a clear message
  # and the operator investigates manually rather than auto-migrating.

  desc "Test key encryption roundtrip"
  task test_encryption: :environment do
    keypair = Solana::Keypair.generate
    address = keypair.to_base58
    encrypted = keypair.encrypt

    restored = Solana::Keypair.from_encrypted(encrypted)

    if restored.to_base58 == address
      puts "Encryption roundtrip: PASS"
      puts "Address: #{address}"
    else
      puts "Encryption roundtrip: FAIL"
      puts "Original: #{address}"
      puts "Restored: #{restored.to_base58}"
    end
  end

  desc "Print SHA256 of the committed turf_vault IDL (config/turf_vault.idl.json)"
  task idl_hash: :environment do
    hash = Solana::Config.idl_hash
    if hash
      puts "SHA256: #{hash}"
      puts ""
      puts "To pin this hash on prod:"
      puts "  heroku config:set EXPECTED_IDL_HASH=#{hash} --app turf-monster-mainnet"
    else
      puts "ERROR: #{Solana::Config::IDL_PATH} not found."
      puts "Pull the deployed IDL first:"
      puts "  anchor idl fetch #{Solana::Config::PROGRAM_ID} --provider.cluster #{Solana::Config::NETWORK} > #{Solana::Config::IDL_PATH}"
      exit 1
    end
  end

  desc "Verify the committed IDL hash matches EXPECTED_IDL_HASH (CI + boot use this)"
  task verify_idl: :environment do
    begin
      Solana::Config.verify_idl!
      puts "IDL hash OK"
    rescue Solana::Config::IdlMismatchError => e
      puts e.message
      exit 1
    end
  end

  desc "End-to-end Solana health check (run on every Heroku flip before traffic)"
  task health: :environment do
    exit_code = 0
    pass = ->(msg) { puts "  ✓ #{msg}" }
    fail = ->(msg) { puts "  ✗ #{msg}"; exit_code = 1 }

    puts "=== Solana health check ==="
    puts "  NETWORK    = #{Solana::Config::NETWORK}"
    puts "  RPC_URL    = #{Solana::Config::RPC_URL.to_s.sub(/api-key=[^&]+/, 'api-key=***')}"
    puts "  PROGRAM_ID = #{Solana::Config::PROGRAM_ID}"
    puts

    # 1. NETWORK is recognized
    known = %w[mainnet-beta devnet testnet]
    if known.include?(Solana::Config::NETWORK)
      pass.("NETWORK is a known cluster")
    else
      fail.("NETWORK=#{Solana::Config::NETWORK.inspect} is not one of #{known.inspect}")
    end

    # 2. Genesis-hash alignment (the same check solana_network_alignment.rb
    # runs at boot, but on-demand for pre-flight + post-flip validation).
    expected = {
      "mainnet-beta" => "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d",
      "devnet"       => "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG",
      "testnet"      => "4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY"
    }[Solana::Config::NETWORK]

    client = Solana::Client.new(rpc_url: Solana::Config::RPC_URL)
    begin
      actual = client.get_genesis_hash
      if expected && actual == expected
        pass.("RPC genesis matches #{Solana::Config::NETWORK}")
      elsif expected
        fail.("RPC genesis mismatch: expected #{expected}, got #{actual}")
      end
    rescue Solana::Client::RpcError => e
      fail.("getGenesisHash failed: #{e.message[0,120]}")
    end

    # 3. PROGRAM_ID exists at this RPC. Reuses the same guard
    # TokenPurchaseJob runs at job start (Solana::Vault.ensure_program_id_live!).
    Rails.cache.delete_matched("solana/program_id_live/v1/*") rescue nil
    begin
      Solana::Vault.ensure_program_id_live!(client: client)
      pass.("PROGRAM_ID exists on RPC")
    rescue Solana::Vault::StaleEnvError => e
      fail.(e.message)
    end

    # 4. EXPECTED_IDL_HASH alignment (production-only gate; surfaced in all envs
    # so a dev can flip it and verify before a Heroku release).
    if Solana::Config::EXPECTED_IDL_HASH.blank?
      puts "  · EXPECTED_IDL_HASH is unset (OK in dev; required in production)"
    else
      committed = Solana::Config.idl_hash
      if Solana::Config.idl_hash_acceptable?(committed)
        pass.("Committed IDL is in the accepted EXPECTED_IDL_HASH set")
      else
        fail.("Committed IDL hash (#{committed}) not in EXPECTED_IDL_HASH set (#{Solana::Config.expected_idl_hashes.join(', ')})")
      end
    end

    # 5. Helius rate-limit headers (informational — flag if we're close to the
    # quota ceiling on free tier).
    begin
      response = client.send_rpc("getHealth")
      if response.respond_to?(:headers)
        rl = response.headers.transform_keys(&:downcase).slice(*%w[x-ratelimit-remaining x-rl-remaining])
        puts "  · Helius rate-limit remaining: #{rl.inspect}" if rl.any?
      end
    rescue
      # Optional; don't fail the health check on missing rate-limit headers.
    end

    puts
    if exit_code.zero?
      puts "OK — Solana stack is healthy on #{Solana::Config::NETWORK}."
    else
      puts "FAIL — fix the above before flipping traffic."
    end
    exit exit_code
  end

  # OPSEC-015: migrate managed-wallet private keys from the legacy encryption
  # scheme (secret_key_base[0,32], ~128-bit) to the current v2 scheme
  # (MANAGED_WALLET_ENCRYPTION_KEY via KeyGenerator, 256-bit). Safe to run
  # anytime — idempotent (skips rows already at v2), non-destructive
  # (re-encrypts to the same plaintext), and roundtrip-verified per row
  # before the write. Run on prod after deploying the OPSEC-015 code +
  # setting MANAGED_WALLET_ENCRYPTION_KEY.
  desc "OPSEC-015: re-encrypt managed-wallet keys to the current (v2) scheme"
  task reencrypt_managed_wallets: :environment do
    scope = User.where.not(encrypted_web2_solana_private_key: [nil, ""])
    total = scope.count
    migrated = skipped = failed = 0
    puts "Re-encrypting #{total} managed-wallet key(s)..."

    scope.find_each do |user|
      current = user.encrypted_web2_solana_private_key
      if Solana::Keypair.current_version?(current)
        skipped += 1
        next
      end
      begin
        fresh = Solana::Keypair.reencrypt(current)
        # Roundtrip sanity: the re-encrypted value MUST decrypt back to the
        # same wallet pubkey before we overwrite the row. Guards against a
        # silent corruption that would lock the user out of their funds.
        roundtrip = Solana::Keypair.from_encrypted(fresh).to_base58
        unless roundtrip == user.web2_solana_address
          raise "roundtrip pubkey mismatch (#{roundtrip} != #{user.web2_solana_address})"
        end
        user.update_column(:encrypted_web2_solana_private_key, fresh)
        migrated += 1
      rescue => e
        failed += 1
        puts "  FAILED user ##{user.id} (#{user.web2_solana_address}): #{e.message}"
      end
    end

    puts "Done: #{migrated} migrated, #{skipped} already v2, #{failed} failed."
    exit 1 if failed.positive?
  end
end
