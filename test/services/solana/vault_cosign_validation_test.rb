require "test_helper"

# Audit C1 — admin blind-cosign. confirm_onchain_entry used to hand raw client
# bytes straight to the admin cosign (Transaction.cosign_wire signs the EXACT
# client message), so a crafted SystemProgram.transfer{from: admin} /
# mint_entry_token / grant_seeds would be admin-signed and broadcast.
#
# Vault#assert_entry_cosign_safe! / #assert_create_contest_cosign_safe! now
# DECODE the Phantom-signed wire and semantically allowlist it BEFORE any admin
# signature: admin fee-payer, exactly one expected turf-vault IX bound to THIS
# server-issued payload, and only fee-capped ComputeBudget and Phantom's Lighthouse
# assertions alongside -- never a System instruction, not even a nonce advance. Byte-equality is intentionally NOT used — the client round-trips the
# tx through web3.js, which may re-encode the message bytes — so these tests
# exercise legit builds via the public builders.
class Solana::VaultCosignValidationTest < ActiveSupport::TestCase
  # A real entrant wallet — MUST differ from the admin managed wallet (the
  # fee-payer): enter_contest marks BOTH admin (payer) and this wallet (user) as
  # signers. (Mason's seed wallet; admin / Alex Bot is 8K81w4e6…aRYd.)
  WALLET = "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR".freeze
  SLUG   = "cosign-validation-test".freeze

  FakeContest = Struct.new(:slug)
  FakeEntry   = Struct.new(:id, :entry_number, :contest)

  def entry_for(entry_number: 0)
    FakeEntry.new(7, entry_number, FakeContest.new(SLUG))
  end

  # 80-byte initialized nonce account: version=1, state=1, authority, nonce, fee.
  def nonce_buffer(authority_b58:, nonce_b58:)
    [1].pack("L<") + [1].pack("L<") +
      Solana::Keypair.decode_base58(authority_b58) +
      Solana::Keypair.decode_base58(nonce_b58) + [5000].pack("Q<")
  end

  def fake_client(nonce_b64: nil)
    c = Object.new
    c.define_singleton_method(:get_account_info) { |_pk, **_o| { "value" => { "data" => [nonce_b64, "base64"] } } }
    c.define_singleton_method(:get_latest_blockhash) { |**_o| Solana::Keypair.generate.to_base58 }
    c
  end

  def create_params
    {
      entry_fee_by_currency: [19_000_000],
      max_entries: 29,
      payout_amounts: [300_000_000, 50_000_000],
      prize_pool: 350_000_000,
      season_id: 1,
      lock_timestamp: 0
    }
  end

  def with_durable_nonce_env(pubkey)
    prev = ENV["SOLANA_DURABLE_NONCE_PUBKEY"]
    ENV["SOLANA_DURABLE_NONCE_PUBKEY"] = pubkey
    yield
  ensure
    if prev.nil? then ENV.delete("SOLANA_DURABLE_NONCE_PUBKEY") else ENV["SOLANA_DURABLE_NONCE_PUBKEY"] = prev end
  end

  setup { @nonce_env_prev = ENV.delete("SOLANA_DURABLE_NONCE_PUBKEY") }
  teardown { ENV["SOLANA_DURABLE_NONCE_PUBKEY"] = @nonce_env_prev unless @nonce_env_prev.nil? }

  # --- legit entries PASS ------------------------------------------------------

  test "a legit enter_contest (no durable nonce) passes" do
    vault = Solana::Vault.new(client: fake_client)
    out = vault.build_enter_contest(WALLET, SLUG, 0, currency_idx: 0, season_id: 1)

    assert vault.assert_entry_cosign_safe!(out[:serialized_tx], entry: entry_for(entry_number: 0), wallet_address: WALLET)
  end

  # --- token-funded entries (Phantom spends an EntryTokenAccount) --------------
  #
  # The guard's expectation comes from the SERVER: #prepare_entry recorded which
  # EntryTokenAccount it built against, and that single fact decides which
  # instruction may be admin-cosigned. These four cases pin both directions of
  # that lock, because a guard that accepts EITHER instruction would let a client
  # turn a USDC entry into a free one — or spend a token the server never chose.

  test "a legit enter_contest_with_token passes when the server prepared that token" do
    vault = Solana::Vault.new(client: fake_client)
    token = Solana::Keypair.generate.to_base58
    out   = vault.build_enter_contest_with_token(WALLET, SLUG, 0, token, season_id: 1)

    assert vault.assert_entry_cosign_safe!(out[:serialized_tx], entry: entry_for(entry_number: 0),
                                                                wallet_address: WALLET,
                                                                entry_token_pda: token)
  end

  test "a token wire spending a DIFFERENT token than the server picked is rejected" do
    vault    = Solana::Vault.new(client: fake_client)
    prepared = Solana::Keypair.generate.to_base58
    other    = Solana::Keypair.generate.to_base58
    out      = vault.build_enter_contest_with_token(WALLET, SLUG, 0, other, season_id: 1)

    # The program refuses a token whose owner is not the signer, so this wire
    # could only ever spend a token this SAME wallet owns — a voucher the server
    # never selected and never accounted for. The guard is the second lock.
    err = assert_raises(Solana::Vault::UnsafeCosignError) do
      vault.assert_entry_cosign_safe!(out[:serialized_tx], entry: entry_for(entry_number: 0),
                                                           wallet_address: WALLET,
                                                           entry_token_pda: prepared)
    end
    assert_match(/entry_token_pda_mismatch/, err.message)
  end

  test "a token wire is rejected when the server prepared a currency transfer" do
    vault = Solana::Vault.new(client: fake_client)
    token = Solana::Keypair.generate.to_base58
    out   = vault.build_enter_contest_with_token(WALLET, SLUG, 0, token, season_id: 1)

    # THE ESCALATION THIS BLOCKS: entry priced in USDC, wire swapped for a free
    # token consume. No entry_token_pda expectation → only enter_contest passes.
    err = assert_raises(Solana::Vault::UnsafeCosignError) do
      vault.assert_entry_cosign_safe!(out[:serialized_tx], entry: entry_for(entry_number: 0),
                                                           wallet_address: WALLET)
    end
    assert_match(/wrong_turf_vault_ix/, err.message)
  end

  test "a transfer wire is rejected when the server prepared a token consume" do
    vault = Solana::Vault.new(client: fake_client)
    out   = vault.build_enter_contest(WALLET, SLUG, 0, currency_idx: 0, season_id: 1)

    err = assert_raises(Solana::Vault::UnsafeCosignError) do
      vault.assert_entry_cosign_safe!(out[:serialized_tx], entry: entry_for(entry_number: 0),
                                                           wallet_address: WALLET,
                                                           entry_token_pda: Solana::Keypair.generate.to_base58)
    end
    assert_match(/wrong_turf_vault_ix/, err.message)
  end

  test "enter_contest_with_token bound to the WRONG entry index is rejected" do
    vault = Solana::Vault.new(client: fake_client)
    token = Solana::Keypair.generate.to_base58
    out   = vault.build_enter_contest_with_token(WALLET, SLUG, 0, token, season_id: 1)

    # Pins the shared account layout the guard leans on: contest_entry sits at
    # ENTER_CONTEST_ENTRY_PDA_POSITION (5) in the token instruction too. Reorder
    # that instruction's accounts and this fails instead of silently checking
    # whatever now occupies slot 5.
    err = assert_raises(Solana::Vault::UnsafeCosignError) do
      vault.assert_entry_cosign_safe!(out[:serialized_tx], entry: entry_for(entry_number: 1),
                                                           wallet_address: WALLET,
                                                           entry_token_pda: token)
    end
    assert_match(/entry_pda_mismatch/, err.message)
  end

  test "a legit create_contest (Phantom-first unsigned wire) passes" do
    vault = Solana::Vault.new(client: fake_client)
    out = vault.build_create_contest(WALLET, SLUG, **create_params, admin_signs: false)

    assert vault.assert_create_contest_cosign_safe!(
      out[:serialized_tx],
      wallet_address: WALLET,
      contest_slug: SLUG,
      onchain_params: create_params
    )
  end

  test "build_enter_contest IGNORES the durable nonce config (entries use a fresh blockhash)" do
    authority = Solana::Keypair.admin.address
    nonce_val = Solana::Keypair.generate.to_base58
    buf   = nonce_buffer(authority_b58: authority, nonce_b58: nonce_val)
    vault = Solana::Vault.new(client: fake_client(nonce_b64: Base64.strict_encode64(buf)))

    # 2026-06-11: entry txs deliberately do NOT anchor on the operator's
    # durable nonce even when SOLANA_DURABLE_NONCE_PUBKEY is set — Phantom
    # injects guard ixs at uncontrolled positions (breaking nonce detection)
    # and a single nonce can't serve concurrent entrants. The built wire must
    # still pass the cosign guard (and contain no advanceNonceAccount ix).
    with_durable_nonce_env(Solana::Keypair.generate.to_base58) do
      out = vault.build_enter_contest(WALLET, SLUG, 0, currency_idx: 0, season_id: 1)
      assert vault.assert_entry_cosign_safe!(out[:serialized_tx], entry: entry_for(entry_number: 0), wallet_address: WALLET)

      decoded = Base64.strict_decode64(out[:serialized_tx])
      advance = Solana::Vault::SYSTEM_ADVANCE_NONCE_DATA
      refute decoded.include?(advance),
             "entry wire must not carry an advanceNonceAccount ix"
    end
  end

  test "a Phantom-injected Lighthouse assertion alongside enter_contest passes" do
    vault = Solana::Vault.new(client: fake_client)
    admin = Solana::Keypair.admin
    entry_pda_bytes = vault.entry_pda(SLUG, WALLET, 0).first

    # Mimic Phantom transaction protection on mainnet: the tx we prepared
    # (enter_contest) PLUS a Lighthouse post-state assertion injected at sign
    # time. Without the allowlist case this rejected with disallowed_program
    # and blocked every protected Phantom entry (prod, 2026-06-11).
    tx = Solana::Transaction.new
    tx.set_recent_blockhash(Solana::Keypair.generate.to_base58)
    tx.add_signer(admin)
    accounts = Array.new(Solana::Vault::ENTER_CONTEST_ENTRY_PDA_POSITION) do
      { pubkey: Solana::Keypair.generate.public_key_bytes, is_signer: false, is_writable: false }
    end
    accounts << { pubkey: entry_pda_bytes, is_signer: false, is_writable: true }
    tx.add_instruction(
      program_id: Solana::Keypair.decode_base58(Solana::Config::PROGRAM_ID),
      accounts: accounts,
      data: Solana::Transaction.anchor_discriminator("enter_contest") + ("\x00".b * 8)
    )
    tx.add_instruction(
      program_id: Solana::Vault::LIGHTHOUSE_PROGRAM_ID,
      accounts: [{ pubkey: Solana::Keypair.decode_base58(WALLET), is_signer: false, is_writable: false }],
      data: "\x02\x00\x01".b # opaque assertion payload — contents are not inspected
    )

    assert vault.assert_entry_cosign_safe!(tx.serialize_base64,
                                           entry: entry_for(entry_number: 0),
                                           wallet_address: WALLET)
  end

  # --- malicious / mismatched wires REJECT ------------------------------------

  test "admin-fee-payer SystemProgram.transfer is rejected (the C1 attack)" do
    vault    = Solana::Vault.new(client: fake_client)
    admin    = Solana::Keypair.admin
    attacker = Solana::Keypair.generate

    tx = Solana::Transaction.new
    tx.set_recent_blockhash(Solana::Keypair.generate.to_base58)
    tx.add_signer(admin)
    tx.add_instruction(
      program_id: Solana::Transaction::SYSTEM_PROGRAM_ID,
      accounts: [
        { pubkey: admin.public_key_bytes,    is_signer: true,  is_writable: true }, # from: admin
        { pubkey: attacker.public_key_bytes, is_signer: false, is_writable: true }  # to:   attacker
      ],
      data: [2].pack("V") + [5_000_000].pack("Q<") # SystemInstruction::Transfer (opcode 2)
    )

    err = assert_raises(Solana::Vault::UnsafeCosignError) do
      vault.assert_entry_cosign_safe!(tx.serialize_base64, entry: entry_for(entry_number: 0), wallet_address: WALLET)
    end
    assert_match(/system_program_ix/, err.message)
  end

  test "admin-fee-payer SystemProgram.transfer is rejected for create_contest cosign" do
    vault    = Solana::Vault.new(client: fake_client)
    admin    = Solana::Keypair.admin
    attacker = Solana::Keypair.generate

    tx = Solana::Transaction.new
    tx.set_recent_blockhash(Solana::Keypair.generate.to_base58)
    tx.add_signer(admin)
    tx.add_instruction(
      program_id: Solana::Transaction::SYSTEM_PROGRAM_ID,
      accounts: [
        { pubkey: admin.public_key_bytes,    is_signer: true,  is_writable: true },
        { pubkey: attacker.public_key_bytes, is_signer: false, is_writable: true }
      ],
      data: [2].pack("V") + [5_000_000].pack("Q<")
    )

    err = assert_raises(Solana::Vault::UnsafeCosignError) do
      vault.assert_create_contest_cosign_safe!(
        tx.serialize_base64,
        wallet_address: WALLET,
        contest_slug: SLUG,
        onchain_params: create_params
      )
    end
    assert_match(/system_program_ix/, err.message)
  end

  test "create_contest signed wire bound to different payload is rejected" do
    vault = Solana::Vault.new(client: fake_client)
    out = vault.build_create_contest(WALLET, SLUG, **create_params, admin_signs: false)

    err = assert_raises(Solana::Vault::UnsafeCosignError) do
      vault.assert_create_contest_cosign_safe!(
        out[:serialized_tx],
        wallet_address: WALLET,
        contest_slug: SLUG,
        onchain_params: create_params.merge(prize_pool: 351_000_000)
      )
    end
    assert_match(/create_data_mismatch/, err.message)
  end

  test "a turf-vault instruction that is not enter_contest is rejected" do
    vault = Solana::Vault.new(client: fake_client)
    admin = Solana::Keypair.admin

    tx = Solana::Transaction.new
    tx.set_recent_blockhash(Solana::Keypair.generate.to_base58)
    tx.add_signer(admin)
    tx.add_instruction(
      program_id: Solana::Keypair.decode_base58(Solana::Config::PROGRAM_ID),
      accounts: [{ pubkey: admin.public_key_bytes, is_signer: true, is_writable: true }],
      data: Solana::Transaction.anchor_discriminator("mint_entry_token") + ("\x00".b * 4)
    )

    err = assert_raises(Solana::Vault::UnsafeCosignError) do
      vault.assert_entry_cosign_safe!(tx.serialize_base64, entry: entry_for(entry_number: 0), wallet_address: WALLET)
    end
    assert_match(/wrong_turf_vault_ix/, err.message)
  end

  test "enter_contest bound to the WRONG entry index is rejected" do
    vault = Solana::Vault.new(client: fake_client)
    out = vault.build_enter_contest(WALLET, SLUG, 0, currency_idx: 0, season_id: 1)

    # The wire enters slot 0, but the server expects entry_number 1 for THIS entry.
    err = assert_raises(Solana::Vault::UnsafeCosignError) do
      vault.assert_entry_cosign_safe!(out[:serialized_tx], entry: entry_for(entry_number: 1), wallet_address: WALLET)
    end
    assert_match(/entry_pda_mismatch/, err.message)
  end

  test "a fee payer that is not the admin wallet is rejected" do
    vault     = Solana::Vault.new(client: fake_client)
    not_admin = Solana::Keypair.generate

    tx = Solana::Transaction.new
    tx.set_recent_blockhash(Solana::Keypair.generate.to_base58)
    tx.add_signer(not_admin)
    tx.add_instruction(
      program_id: Solana::Keypair.decode_base58(Solana::Config::PROGRAM_ID),
      accounts: [{ pubkey: not_admin.public_key_bytes, is_signer: true, is_writable: true }],
      data: Solana::Transaction.anchor_discriminator("enter_contest") + [0].pack("V") + [0].pack("C")
    )

    err = assert_raises(Solana::Vault::UnsafeCosignError) do
      vault.assert_entry_cosign_safe!(tx.serialize_base64, entry: entry_for(entry_number: 0), wallet_address: WALLET)
    end
    assert_match(/fee_payer_not_admin/, err.message)
  end

  test "an advanceNonceAccount with NO durable nonce configured is rejected" do
    # Hand-build a wire carrying an advance ix (build_enter_contest no longer
    # emits one — entries use a fresh blockhash since 2026-06-11), validated
    # with the env UNSET — a wire smuggling a nonce advance the server never
    # configured must not be blind-cosigned.
    vault = Solana::Vault.new(client: fake_client)
    admin = Solana::Keypair.admin

    tx = Solana::Transaction.new
    tx.set_recent_blockhash(Solana::Keypair.generate.to_base58)
    tx.add_signer(admin)
    adv = Solana::SystemProgram.advance_nonce_account(
      nonce: Solana::Keypair.generate.to_base58, authority: admin.address
    )
    tx.add_instruction(program_id: adv[:program_id], accounts: adv[:accounts], data: adv[:data])

    err = assert_raises(Solana::Vault::UnsafeCosignError) do
      vault.assert_entry_cosign_safe!(tx.serialize_base64, entry: entry_for(entry_number: 0), wallet_address: WALLET)
    end
    assert_match(/advance_nonce_rejected/, err.message)
  end

  # --- reject-vestigial-nonce-cosign-advance -----------------------------------
  #
  # THE HOLE. Both guards admitted a System advanceNonceAccount as long as it
  # targeted the CONFIGURED SOLANA_DURABLE_NONCE_PUBKEY, at ANY position. No
  # wire that reaches either guard carries one: build_enter_contest sets dn = nil,
  # build_enter_contest_with_token passes no nonce, and every guarded create is
  # built with admin_signs: false (durable_nonce: nil). The nonce's authority is
  # the admin -- the very key these guards decide whether to sign with. So a user
  # could append an advance of the OPERATOR's nonce to their own entry or create,
  # and the admin cosign would authorize it, stranding any operator tx anchored
  # on the old nonce value. Griefing, not theft -- but it is signature authority
  # on the money path that no builder asks for.
  #
  # Each case below runs WITH the nonce configured (the only state in which the
  # old guard admitted it) and pairs the rejected wire with the SAME wire minus
  # the advance, which must still pass -- so a rejection can only be about the
  # advance, never about a malformed test wire.

  def configured_nonce = @configured_nonce ||= Solana::Keypair.generate.to_base58

  def operator_advance_ix
    adv = Solana::SystemProgram.advance_nonce_account(nonce: configured_nonce, authority: Solana::Keypair.admin.address)
    { program_id: adv[:program_id], accounts: adv[:accounts], data: adv[:data] }
  end

  # A Phantom-first shaped wire (no local signer; admin reserved as fee payer,
  # the creator/entrant second) carrying `program_ix`, with the operator-nonce
  # advance at `advance_at` (:first, :last) or absent (nil).
  def wire(program_ix, advance_at: nil)
    tx = Solana::Transaction.new
    tx.set_recent_blockhash(Solana::Keypair.generate.to_base58)
    tx.add_instruction(**operator_advance_ix) if advance_at == :first
    tx.add_instruction(**program_ix)
    tx.add_instruction(**operator_advance_ix) if advance_at == :last
    tx.serialize_partial_base64(additional_signers: [Solana::Keypair.admin.public_key_bytes,
                                                     Solana::Keypair.decode_base58(WALLET)])
  end

  def enter_contest_ix(vault)
    accounts = Array.new(Solana::Vault::ENTER_CONTEST_ENTRY_PDA_POSITION) do
      { pubkey: Solana::Keypair.generate.public_key_bytes, is_signer: false, is_writable: false }
    end
    accounts << { pubkey: vault.entry_pda(SLUG, WALLET, 0).first, is_signer: false, is_writable: true }
    { program_id: Solana::Keypair.decode_base58(Solana::Config::PROGRAM_ID), accounts: accounts,
      data: Solana::Transaction.anchor_discriminator("enter_contest") + ("\x00".b * 8) }
  end

  def create_contest_ix(vault)
    spec = vault.create_contest_instruction(WALLET, SLUG, **create_params)
    { program_id: Solana::Keypair.decode_base58(Solana::Config::PROGRAM_ID), accounts: spec[:accounts], data: spec[:data] }
  end

  def entry_guard(vault, wire_b64)
    vault.assert_entry_cosign_safe!(wire_b64, entry: entry_for(entry_number: 0), wallet_address: WALLET)
  end

  def create_guard(vault, wire_b64)
    vault.assert_create_contest_cosign_safe!(wire_b64, wallet_address: WALLET, contest_slug: SLUG,
                                                       onchain_params: create_params)
  end

  %i[first last].each do |position|
    test "REGRESSION: an entry wire advancing the CONFIGURED operator nonce (#{position}) is refused" do
      vault = Solana::Vault.new(client: fake_client)
      with_durable_nonce_env(configured_nonce) do
        ix = enter_contest_ix(vault)
        assert entry_guard(vault, wire(ix)), "control: the same entry wire without the advance must pass"

        err = assert_raises(Solana::Vault::UnsafeCosignError) { entry_guard(vault, wire(ix, advance_at: position)) }
        assert_match(/advance_nonce_rejected/, err.message)
      end
    end

    test "REGRESSION: a create wire advancing the CONFIGURED operator nonce (#{position}) is refused" do
      vault = Solana::Vault.new(client: fake_client)
      with_durable_nonce_env(configured_nonce) do
        ix = create_contest_ix(vault)
        assert create_guard(vault, wire(ix)), "control: the same create wire without the advance must pass"

        err = assert_raises(Solana::Vault::UnsafeCosignError) { create_guard(vault, wire(ix, advance_at: position)) }
        assert_match(/advance_nonce_rejected/, err.message)
      end
    end
  end

  # CONTROL: every shape a guarded flow's BUILDER actually produces still passes
  # with the nonce configured -- the production-shaped state. If any of these
  # carried an advance, tightening the guard would break it. Once the guard
  # refuses every System instruction, these passing IS the proof that no builder
  # feeding a guard emits one.
  test "control: every guarded builder's wire passes with the durable nonce configured" do
    vault = Solana::Vault.new(client: fake_client)
    token_pda = Solana::Keypair.generate.to_base58
    with_durable_nonce_env(configured_nonce) do
      entry = vault.build_enter_contest(WALLET, SLUG, 0, currency_idx: 0, season_id: 1)
      assert entry_guard(vault, entry[:serialized_tx])

      token = vault.build_enter_contest_with_token(WALLET, SLUG, 0, token_pda, season_id: 1)
      assert vault.assert_entry_cosign_safe!(token[:serialized_tx], entry: entry_for(entry_number: 0),
                                                                      wallet_address: WALLET, entry_token_pda: token_pda)

      create = vault.build_create_contest(WALLET, SLUG, **create_params, admin_signs: false)
      assert create_guard(vault, create[:serialized_tx])
    end
  end

  # --- cap-cosign-priority-fee ---------------------------------------------------
  #
  # THE HOLE. Both guards admitted EVERY ComputeBudget instruction without reading
  # it. The fee payer is the admin, and Solana charges the fee payer a priority
  # fee of compute_unit_price x compute_unit_limit / 1e6 lamports -- charged even
  # when the transaction then fails. So a user could take their own prepared entry,
  # raise the price, sign, and POST it: the guard passed, the admin cosigned as
  # fee payer, and the admin paid the leader. Carl's review probe: 1_400_000 CU x
  # 5e10 micro-lamports/CU (a 70 SOL fee) returned true.
  #
  # These regression cases use only values the ORIGINAL code already knew about
  # (the builder's own constants), so they fail today for the reason under test
  # and not for a missing constant.

  def cu_limit_ix(units) = { program_id: Solana::Vault::COMPUTE_BUDGET_PROGRAM_ID, accounts: [],
                             data: "\x02".b + [units].pack("V") }

  def cu_price_ix(micro_lamports) = { program_id: Solana::Vault::COMPUTE_BUDGET_PROGRAM_ID, accounts: [],
                                      data: "\x03".b + [micro_lamports].pack("Q<") }

  # The prepared shape -- ComputeBudget ixs first, then the program ix -- as a
  # Phantom-first wire with the admin reserved as fee payer.
  def budget_wire(program_ix, budget_ixs)
    tx = Solana::Transaction.new
    tx.set_recent_blockhash(Solana::Keypair.generate.to_base58)
    budget_ixs.each { |ix| tx.add_instruction(**ix) }
    tx.add_instruction(**program_ix)
    tx.serialize_partial_base64(additional_signers: [Solana::Keypair.admin.public_key_bytes,
                                                     Solana::Keypair.decode_base58(WALLET)])
  end

  BUILDER_PRICE = Solana::Vault::PARTIAL_TX_PRIORITY_FEE_MICROLAMPORTS
  BUILDER_LIMIT = Solana::Vault::PARTIAL_TX_COMPUTE_UNIT_LIMIT

  {
    "Carl's probe: 1.4M CU at 5e10 micro-lamports/CU (70 SOL)" => [1_400_000, 50_000_000_000],
    "the builder's own limit at 1000x the builder's price"      => [BUILDER_LIMIT, BUILDER_PRICE * 1000]
  }.each do |label, (limit, price)|
    test "REGRESSION: the entry guard refuses an admin-paid priority fee -- #{label}" do
      vault = Solana::Vault.new(client: fake_client)
      ix = enter_contest_ix(vault)
      assert entry_guard(vault, budget_wire(ix, [cu_limit_ix(BUILDER_LIMIT), cu_price_ix(BUILDER_PRICE)])),
             "control: the same entry at the builder's own fee must pass"

      assert_raises(Solana::Vault::UnsafeCosignError) do
        entry_guard(vault, budget_wire(ix, [cu_limit_ix(limit), cu_price_ix(price)]))
      end
    end

    test "REGRESSION: the create guard refuses an admin-paid priority fee -- #{label}" do
      vault = Solana::Vault.new(client: fake_client)
      ix = create_contest_ix(vault)
      assert create_guard(vault, budget_wire(ix, [cu_limit_ix(BUILDER_LIMIT), cu_price_ix(BUILDER_PRICE)])),
             "control: the same create at the builder's own fee must pass"

      assert_raises(Solana::Vault::UnsafeCosignError) do
        create_guard(vault, budget_wire(ix, [cu_limit_ix(limit), cu_price_ix(price)]))
      end
    end
  end

  # --- the ceiling itself (derived from the builders; see COSIGN_FEE_MARGIN) -------

  CAP_PRICE = Solana::Vault::COSIGN_MAX_COMPUTE_UNIT_PRICE

  def refused(vault, program_ix, budget_ixs, guard: :entry)
    assert_raises(Solana::Vault::UnsafeCosignError) do
      w = budget_wire(program_ix, budget_ixs)
      guard == :entry ? entry_guard(vault, w) : create_guard(vault, w)
    end.message
  end

  test "a wallet-raised price up to the ceiling is cosigned -- cap, not refuse" do
    vault = Solana::Vault.new(client: fake_client)
    assert entry_guard(vault, budget_wire(enter_contest_ix(vault), [cu_limit_ix(BUILDER_LIMIT), cu_price_ix(CAP_PRICE)]))
    assert create_guard(vault, budget_wire(create_contest_ix(vault), [cu_limit_ix(BUILDER_LIMIT), cu_price_ix(CAP_PRICE)]))
  end

  test "one micro-lamport per CU over the price ceiling is refused, by both guards" do
    vault = Solana::Vault.new(client: fake_client)
    over = [cu_limit_ix(BUILDER_LIMIT), cu_price_ix(CAP_PRICE + 1)]
    assert_match(/compute_unit_price_over_cap/, refused(vault, enter_contest_ix(vault), over))
    assert_match(/compute_unit_price_over_cap/, refused(vault, create_contest_ix(vault), over, guard: :create))
  end

  test "a price at the ceiling with a raised limit is refused once the admin's fee passes the cap" do
    vault = Solana::Vault.new(client: fake_client)
    ix = enter_contest_ix(vault)
    assert_match(/priority_fee_over_cap/, refused(vault, ix, [cu_limit_ix(BUILDER_LIMIT + 1), cu_price_ix(CAP_PRICE)]))
  end

  test "a price with no limit is charged at the runtime maximum, never under-counted" do
    vault = Solana::Vault.new(client: fake_client)
    ix = enter_contest_ix(vault)
    # 50_000 x 1_400_000 = 0.7 of the ceiling: passes. Double the price: 1.4x -- refused.
    assert entry_guard(vault, budget_wire(ix, [cu_price_ix(BUILDER_PRICE)]))
    assert_match(/priority_fee_over_cap/, refused(vault, ix, [cu_price_ix(BUILDER_PRICE * 2)]))
  end

  test "only SetComputeUnitLimit and SetComputeUnitPrice are admitted, once each, well-formed" do
    vault = Solana::Vault.new(client: fake_client)
    ix = enter_contest_ix(vault)
    heap = { program_id: Solana::Vault::COMPUTE_BUDGET_PROGRAM_ID, accounts: [], data: "\x01".b + [256 * 1024].pack("V") }
    deprecated = { program_id: Solana::Vault::COMPUTE_BUDGET_PROGRAM_ID, accounts: [],
                   data: "\x00".b + [1_400_000].pack("V") + [1_000_000_000].pack("V") } # RequestUnits: units + additional_fee
    short_price = { program_id: Solana::Vault::COMPUTE_BUDGET_PROGRAM_ID, accounts: [], data: "\x03".b + [1].pack("V") }

    assert_match(/compute_budget_ix_not_allowed/, refused(vault, ix, [heap]))
    assert_match(/compute_budget_ix_not_allowed/, refused(vault, ix, [deprecated]))
    assert_match(/compute_budget_malformed/, refused(vault, ix, [short_price]))
    assert_match(/compute_budget_duplicate/,
                 refused(vault, ix, [cu_price_ix(1), cu_limit_ix(BUILDER_LIMIT), cu_price_ix(1)]))
  end
end
