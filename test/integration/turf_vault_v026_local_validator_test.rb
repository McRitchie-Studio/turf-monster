require "test_helper"

# [integration] The v0.26 readiness fixes LAND on a real turf-vault v0.26
# program, on a local validator (v026-program-readiness-fixes).
#
# Unit tests prove the account lists; they cannot prove the program accepts
# them, and error 6046 is the program's verdict, not Rails's. So this test
# drives the app's own builders against `solana-test-validator` running the
# v0.26 binary built from turf-vault `origin/main`, with a vault this test
# initializes, a GovernanceConfig it bootstraps, and a five-slot signer set:
#
#   1. the operator's Phantom lock and conclusion land (and the pre-fix shape,
#      `cosigner: None`, is refused 6046 by the same program);
#   2. the server-signed lock behind `contests:nfl_sunday_lock`
#      (Contests::ApplyNflSundayLock) lands with a cosigner, and without one
#      is refused in Rails before anything is sent;
#   3. CosignPlan sizes a cancel from the stored GovernanceConfig after an
#      on-chain retune, accepts signers seated in slots 4 and 5, and the cancel
#      lands — where the default sizing is refused 6046;
#   4. a settle signed by the server and the platform cosigner
#      (Solana::PlatformCosigner) is refused 6046 alone, has exactly one slot
#      left, and lands with the operator's one signature.
#
# SKIPPED unless TURF_VAULT_V026_VALIDATOR=1. It needs a validator and a
# v0.26 build, so it runs through `bin/v026-local-validator-proof`, which boots
# both and sets the boot-time env this file relies on (SOLANA_RPC_URL on
# localhost, SOLANA_VAULT_GOVERNANCE=on, test-only SOLANA_ADMIN_KEY and mints).
# Every key here is derived from a published test seed; none holds value or
# exists on any cluster.
class TurfVaultV026LocalValidatorTest < ActiveSupport::TestCase
  self.use_transactional_tests = true

  SEED = "turf-monster v026 local validator proof".freeze
  ROLES = %w[operator cosigner3 cosigner4 cosigner5 creator usdc_mint usdt_mint treasury].freeze
  INSUFFICIENT_SIGNERS = 6046

  def self.key(role) = Solana::Keypair.from_bytes(Digest::SHA256.digest("#{SEED}:#{role}"))

  def self.enabled?
    ENV["TURF_VAULT_V026_VALIDATOR"] == "1"
  end

  setup do
    skip "local v0.26 validator proof — run bin/v026-local-validator-proof" unless self.class.enabled?
    assert Solana::Config.governance?, "the proof runs the v0.26 shape (SOLANA_VAULT_GOVERNANCE=on)"
    assert_match(%r{\Ahttp://(127\.0\.0\.1|localhost):}, Solana::Config::RPC_URL, "never a real cluster")

    @server = Solana::Keypair.admin
    @operator, @c3, @c4, @c5, @creator = %w[operator cosigner3 cosigner4 cosigner5 creator].map { |r| self.class.key(r) }
    @client = Solana::Config.client
    @vault = Solana::Vault.new
    self.class.bootstrap!(self)
    Current.reset
  end

  # ── 1. the operator's Phantom lock and conclusion ──────────────────────────

  test "the pre-fix operator lock (cosigner: None) is refused 6046 by the v0.26 program" do
    slug = create_contest!(lock: Time.now.to_i + 86_400)
    c_pda, _ = @vault.contest_pda(slug)
    vault_pda, _ = @vault.vault_state_pda
    gov, _ = @vault.governance_pda
    accounts = [
      { pubkey: @operator.public_key_bytes, is_signer: true, is_writable: true },
      { pubkey: program_id, is_signer: false, is_writable: false },
      { pubkey: vault_pda, is_signer: false, is_writable: false },
      { pubkey: gov, is_signer: false, is_writable: false },
      { pubkey: c_pda, is_signer: false, is_writable: true }
    ]
    data = Solana::Transaction.anchor_discriminator("set_contest_lock_time") + Solana::Borsh.encode_i64(Time.now.to_i + 7200)

    assert_equal INSUFFICIENT_SIGNERS, simulate_error(signed_tx([@server, @operator], accounts, data))
  end

  test "the operator's Phantom lock lands on v0.26 with the server as second signer" do
    slug = create_contest!(lock: Time.now.to_i + 86_400)
    ts = Time.now.to_i + 7200

    signature = phantom_contest_time("set_contest_lock_time", slug, ts)

    assert signature.present?
    assert_equal ts, @vault.read_contest(slug)[:lock_timestamp]
  end

  test "the operator's Phantom conclusion lands, and an amend is refused in Rails" do
    slug = create_contest!(lock: Time.now.to_i + 86_400)
    ts = Time.now.to_i + 172_800

    phantom_contest_time("set_contest_conclusion_time", slug, ts)
    assert_equal ts, @vault.read_contest(slug)[:conclusion_timestamp]

    error = assert_raises(Solana::Vault::ThresholdUnreachableError) do
      @vault.build_set_contest_conclusion_time(slug, ts + 60, admin_pubkey: @operator.address)
    end
    assert_match(/set_contest_conclusion_time_amend needs 3/, error.message)
  end

  # ── 2. ApplyNflSundayLock's server-signed lock ────────────────────────────

  test "contests:nfl_sunday_lock moves an on-chain lock with a cosigner" do
    thursday, sunday_game = upcoming_nfl_week
    contest = nfl_contest!(thursday, sunday_game)
    create_contest!(slug: contest.slug, lock: thursday.to_i)
    new_lock = contest.slate.default_contest_lock_at

    blocked = Contests::ApplyNflSundayLock.new(write: true, slugs: [contest.slug], vault: @vault, out: StringIO.new).call
    assert_equal :error, blocked.first.action
    assert_match(/ThresholdUnreachable/, blocked.first.reason, "one key is refused in Rails, before a fee")
    assert_equal thursday.to_i, @vault.read_contest(contest.slug)[:lock_timestamp]

    rows = Contests::ApplyNflSundayLock.new(write: true, slugs: [contest.slug], vault: @vault, out: StringIO.new,
                                            cosigners: [@c3]).call
    assert_equal :moved, rows.first.action, rows.first.reason
    assert_equal new_lock.to_i, @vault.read_contest(contest.slug)[:lock_timestamp]
    assert_equal new_lock.to_i, contest.reload.starts_at.to_i
  end

  # ── 3. CosignPlan reads the chain ─────────────────────────────────────────

  test "CosignPlan sizes a cancel from the stored table and the cancel lands" do
    slug = create_contest!(lock: Time.now.to_i + 86_400)
    retune!("cancel_contest", 4)

    plan = Solana::CosignPlan.new(tx_type: "cancel_contest")
    assert_equal 4, plan.required_signatures, "read from GovernanceConfig, not the default 3"
    assert_equal 2, plan.extra_cosigners_needed
    extras = plan.validate_extras!([@c4.address, @c5.address], primary: @operator.address)
    refute_includes Solana::Config::MULTISIG_SIGNERS, @c4.address, "slots 4 and 5 are seated only on chain"

    # The default sizing (one extra) is what the program refuses.
    short = @vault.build_cancel_contest(slug, creator_pubkey: @creator.address, cosigner_pubkey: @operator.address,
                                              extra_cosigners: [@c4.address])
    assert_equal INSUFFICIENT_SIGNERS, simulate_error(cosign(short[:serialized_tx], [@operator, @c4]))

    built = @vault.build_cancel_contest(slug, creator_pubkey: @creator.address, cosigner_pubkey: @operator.address,
                                              extra_cosigners: extras)
    @client.send_and_confirm(cosign(built[:serialized_tx], [@operator, @c4, @c5]))
    assert_equal "cancelled", @vault.read_contest(slug)[:status].to_s.downcase
  ensure
    retune!("cancel_contest", 3) if self.class.enabled?
  end

  # ── 4. the platform's second signature on a settle ────────────────────────
  #
  # Mr. McRitchie's 2026-10-24 ruling: the server (admin) and the platform
  # cosigner sign a settle, and his wallet is the third and final signature.
  # Here cosigner3 plays the platform cosigner and `operator` plays his wallet
  # (the runner names it SOLANA_MULTISIG_COSIGNER, so the boot check treats it
  # as his and refuses it as a platform key).

  test "a settle with two platform signatures accepts exactly one more and lands" do
    platform = Solana::PlatformCosigner.load(
      env: { Solana::PlatformCosigner::ENV_KEY => Solana::Keypair.encode_base58(@c3.to_bytes) },
      network: Solana::Config::NETWORK, expected: @c3.address
    )
    assert platform.configured?, platform.notice
    refused = Solana::PlatformCosigner.load(
      env: { Solana::PlatformCosigner::ENV_KEY => Solana::Keypair.encode_base58(@operator.to_bytes) },
      network: Solana::Config::NETWORK, expected: @operator.address
    )
    assert_equal :refused, refused.state, "the operator's wallet is never a platform key"

    plan = Solana::CosignPlan.new(tx_type: "settle_contest")
    assert_equal 3, plan.required_signatures
    assert plan.platform_cosign?(platform: platform), "seated, configured, and one slot left for the operator"

    slug = create_contest!(lock: Time.now.to_i + 4)
    wait_for_lock!(slug)

    # The platform ALONE cannot settle: two signatures against three.
    alone = @vault.build_settle_contest(slug, [], cosigner_pubkey: platform.address)
    assert_equal INSUFFICIENT_SIGNERS, simulate_error(platform.sign_wire_base64(alone[:serialized_tx]))

    # What the Treasury builds: platform in the named slot, his wallet in the extra.
    built = @vault.build_settle_contest(slug, [], cosigner_pubkey: platform.address,
                                                  extra_cosigners: [@operator.address])
    two = platform.sign_wire_base64(built[:serialized_tx])
    wire = Solana::WireMessage.parse_base64(two)
    keys = wire.signer_keys.map(&:b)
    slot = ->(kp) { keys.index(kp.public_key_bytes) }
    assert_equal 3, keys.length, "three signer slots, no more"
    assert wire.signature_valid?(slot.(@server)) && wire.signature_valid?(slot.(@c3)), "server and platform signed"
    assert wire.signature_slot_empty?(slot.(@operator)), "the operator's slot is the only one left"
    assert_raises(RuntimeError, "no slot exists for a fourth signer") do
      Solana::Transaction.cosign_wire_base64(two, signer: @c4, require_complete: false)
    end

    signature = @client.send_and_confirm(
      Solana::Transaction.cosign_wire_base64(two, signer: @operator, require_complete: true)
    )
    self.class.finalize!(@client, signature)
    puts "\n[platform-cosign proof] settle #{slug} landed: #{signature}"
    assert_equal "settled", @vault.read_contest(slug)[:status].to_s.downcase
  end

  # ── harness ───────────────────────────────────────────────────────────────

  private

  def program_id = Solana::Keypair.decode_base58(Solana::Config::PROGRAM_ID)

  # What the operator's browser and the confirm endpoint do, end to end: the
  # server builds, Phantom signs its one slot, the server verifies the wire
  # against the rebuilt expectation, fills the fee payer, and broadcasts.
  def phantom_contest_time(instruction, slug, ts)
    built = @vault.send(:build_contest_time, instruction, slug, ts, admin_pubkey: @operator.address)
    signed = Solana::Transaction.cosign_wire_base64(built[:serialized_tx], signer: @operator, require_complete: false)
    expectation = @vault.contest_time_expectation(instruction, slug, ts, admin_pubkey: @operator.address)
    @vault.cosign_and_broadcast_contest_time(signed, expectation: expectation)
  end

  # settle_contest refuses (6028 ContestNotLocked) until the lock has passed
  # on the clock of the bank the send preflights against, which is the
  # FINALIZED one here (about 32 slots behind), so wait on that clock.
  def wait_for_lock!(slug)
    lock = @vault.read_contest(slug)[:lock_timestamp].to_i
    120.times do
      slot = @client.send(:call, "getSlot", [{ commitment: "finalized" }])
      block_time = (@client.send(:call, "getBlockTime", [slot]) rescue nil).to_i
      return if block_time > lock

      sleep 0.5
    end
    flunk "the validator clock never passed the lock (#{lock})"
  end

  def cosign(wire, signers)
    signers.each_with_index.reduce(wire) do |w, (kp, i)|
      Solana::Transaction.cosign_wire_base64(w, signer: kp, require_complete: i == signers.size - 1)
    end
  end

  def signed_tx(signers, accounts, data, program: program_id)
    tx = Solana::Transaction.new
    tx.set_recent_blockhash(@client.get_latest_blockhash)
    signers.each { |kp| tx.add_signer(kp) }
    tx.add_instruction(program_id: program, accounts: accounts, data: data)
    tx.serialize_base64
  end

  # The program's custom error code for a transaction it refuses.
  def simulate_error(wire)
    err = @client.simulate_transaction(wire, sig_verify: true)&.dig("err") ||
          flunk("expected the program to refuse this transaction")
    err.dig("InstructionError", 1, "Custom") || flunk("not a program error: #{err.inspect}")
  end

  def create_contest!(lock:, slug: "v026-proof-#{SecureRandom.hex(4)}")
    built = @vault.build_create_contest(@creator.address, slug, entry_fee_by_currency: [0], max_entries: 10,
                                                                payout_amounts: [1_000_000], prize_pool: 1_000_000,
                                                                season_id: 0, lock_timestamp: lock)
    self.class.finalize!(@client, @client.send_and_confirm(cosign(built[:serialized_tx], [@creator])))
    slug
  end

  def retune!(action, value)
    vault_pda, _ = @vault.vault_state_pda
    gov, _ = @vault.governance_pda
    accounts = [
      { pubkey: @server.public_key_bytes, is_signer: true, is_writable: true },
      { pubkey: vault_pda, is_signer: false, is_writable: false },
      { pubkey: gov, is_signer: false, is_writable: true },
      { pubkey: @operator.public_key_bytes, is_signer: true, is_writable: false },
      { pubkey: @c3.public_key_bytes, is_signer: true, is_writable: false }
    ]
    data = Solana::Transaction.anchor_discriminator("set_action_threshold") +
           Solana::Borsh.encode_u8(Solana::Governance::ACTION_IDS.fetch(action)) + Solana::Borsh.encode_u8(value)
    self.class.finalize!(@client, @client.send_and_confirm(signed_tx([@server, @operator, @c3], accounts, data)))
  end

  # A Thursday-opening NFL week far enough out that every lock is in the
  # future on the validator's real clock.
  def upcoming_nfl_week
    zone = ActiveSupport::TimeZone[Contest::LockRule::ZONE]
    date = Date.current + 7
    date += 1 until date.thursday?
    [zone.local(date.year, date.month, date.day, 18, 15), zone.local((date + 3).year, (date + 3).month, (date + 3).day, 14, 25)]
  end

  def nfl_contest!(thursday, sunday_game)
    slate = Slate.create!(name: "NFL v026 proof #{SecureRandom.hex(3)}", week: 9)
    { %w[team-a team-b] => thursday, %w[team-c team-d] => sunday_game }.each do |(home, away), kickoff|
      game = Game.create!(home_team_slug: home, away_team_slug: away, kickoff_at: kickoff, status: "scheduled")
      [[home, away], [away, home]].each do |team, opponent|
        SlateMatchup.create!(slate: slate, team_slug: team, opponent_team_slug: opponent, game_slug: game.slug,
                             rank: 1, turf_score: 1.0, status: "pending")
      end
    end
    Contest.create!(name: "NFL #{SecureRandom.hex(3)}", slate: slate, rank: 8000 + rand(900),
                    contest_type: "standard", user: users(:alex), status: "open", max_entries: 29,
                    starts_at: thursday, onchain_contest_id: "pda-#{SecureRandom.hex(3)}")
  end

  # ── one-time chain setup, shared by every test in the process ─────────────

  class << self
    def bootstrap!(t)
      return if @bootstrapped

      server = Solana::Keypair.admin
      operator, c3, c4, c5, creator, usdc, usdt, treasury = ROLES.map { |r| key(r) }
      client = Solana::Config.client
      vault = Solana::Vault.new

      [server, operator, c3, creator].each { |kp| airdrop(client, kp) }
      [usdc, usdt].each { |mint| create_mint(t, client, server, mint) }
      t.assert_equal usdc.address, Solana::Config::USDC_MINT, "the runner points the app at this mint"

      ata, _ = Solana::SplToken.find_associated_token_address(creator.address, usdc.address)
      send_ixs(client, [server], [
        Solana::SplToken.create_associated_token_account_instruction(payer: server.address, wallet: creator.address,
                                                                     mint: usdc.address),
        Solana::SplToken.mint_to_instruction(mint: usdc.address, destination: Solana::Keypair.encode_base58(ata),
                                             authority: server.address, amount: 1_000_000_000)
      ])

      finalize!(client, vault.initialize_vault(signers: [server.address, operator.address, c3.address], threshold: 2,
                                               treasury_authority: treasury.address)[:signature])

      vault_pda, _ = vault.vault_state_pda
      gov, _ = vault.governance_pda
      program = Solana::Keypair.decode_base58(Solana::Config::PROGRAM_ID)
      # init_governance: two members of the current set (BOOTSTRAP_THRESHOLD).
      send_ixs(client, [server, operator], [{
        program_id: program,
        accounts: [
          { pubkey: server.public_key_bytes, is_signer: true, is_writable: true },
          { pubkey: vault_pda, is_signer: false, is_writable: false },
          { pubkey: gov, is_signer: false, is_writable: true },
          { pubkey: Solana::Transaction::SYSTEM_PROGRAM_ID, is_signer: false, is_writable: false },
          { pubkey: operator.public_key_bytes, is_signer: true, is_writable: false }
        ],
        data: Solana::Transaction.anchor_discriminator("init_governance")
      }])

      # ADD: three signers to five, authorized by all three (UPDATE_SIGNERS 3).
      new_set = [server, operator, c3, c4, c5].map { |kp| Solana::Borsh.encode_pubkey(kp.public_key_bytes) }.join
      send_ixs(client, [server, operator, c3], [{
        program_id: program,
        accounts: [
          { pubkey: server.public_key_bytes, is_signer: true, is_writable: true },
          { pubkey: operator.public_key_bytes, is_signer: true, is_writable: false },
          { pubkey: vault_pda, is_signer: false, is_writable: true },
          { pubkey: gov, is_signer: false, is_writable: false },
          { pubkey: c3.public_key_bytes, is_signer: true, is_writable: false }
        ],
        data: Solana::Transaction.anchor_discriminator("update_signers") + new_set
      }])

      seated = vault.read_vault_state[:active_signers]
      t.assert_equal [server, operator, c3, c4, c5].map(&:address), seated
      @bootstrapped = true
    end

    private

    def airdrop(client, kp)
      sig = client.request_airdrop(kp.address, 50_000_000_000)
      30.times do
        break if client.get_balance(kp.address)&.dig("value").to_i.positive?
        sleep 0.5
      end
      sig
    end

    MINT_LEN = 82
    INITIALIZE_MINT2 = 20

    def create_mint(t, client, payer, mint)
      return if client.get_account_info(mint.address, commitment: "confirmed")&.dig("value")

      lamports = client.get_minimum_balance_for_rent_exemption(MINT_LEN)
      create = Solana::SystemProgram.create_account(from: payer.address, new_account: mint.address, lamports: lamports,
                                                    space: MINT_LEN, owner: Solana::Transaction::TOKEN_PROGRAM_ID)
      init = {
        program_id: Solana::Transaction::TOKEN_PROGRAM_ID,
        accounts: [{ pubkey: mint.public_key_bytes, is_signer: false, is_writable: true }],
        data: [INITIALIZE_MINT2, 6].pack("CC") + payer.public_key_bytes + [0].pack("C")
      }
      send_ixs(client, [payer, mint], [create, init])
      t.assert client.get_account_info(mint.address, commitment: "confirmed")&.dig("value"), "mint #{mint.address} created"
    end

    def send_ixs(client, signers, instructions)
      tx = Solana::Transaction.new
      tx.set_recent_blockhash(client.get_latest_blockhash)
      signers.each { |kp| tx.add_signer(kp) }
      instructions.each { |ix| tx.add_instruction(**ix) }
      finalize!(client, client.send_and_confirm(tx.serialize_base64))
    end

    # The app's server-signed paths preflight at the RPC's default commitment,
    # `finalized`, so an account this setup created is invisible to them until
    # its transaction finalizes (about 32 slots on a local validator). Waiting
    # here is what keeps a setup write from reading as "incorrect program id"
    # or "account not found" to the next transaction.
    def finalize!(client, signature)
      80.times do
        status = client.confirm_transaction(signature, commitment: "finalized")&.dig("value", 0)
        return signature if status && status["confirmationStatus"] == "finalized"

        sleep 0.5
      end
      raise "#{signature} did not finalize"
    end
    public :finalize!
  end
end
