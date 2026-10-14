require "test_helper"

# [unit] Solana::ConsoleNonce: the signer console's durable nonce. Its address
# is derived from the server key, it is ready only while the chain holds an
# initialized, System-owned nonce whose authority IS the server key, and the
# wires it builds are the server's alone.
class Solana::ConsoleNonceTest < ActiveSupport::TestCase
  SYSTEM_OWNER = Solana::ConsoleNonce::SYSTEM_PROGRAM_B58

  # Pinned against @solana/web3.js 1.98.4:
  #   PublicKey.createWithSeed(EQGF…, "turf-signer-console", SystemProgram.programId)
  #   SystemProgram.createAccountWithSeed({ from = base = EQGF…, lamports: 1447680, space: 80, owner: System })
  BASE = "EQGFJAcABtDb6VXtiijTjZ6cE2UqdvhnqJvoharJbpMJ".freeze
  DERIVED = "9nL64UGmTj636sCMnds8yYXFD8HAMGK9bJnuXPoTyL7X".freeze
  CREATE_DATA_HEX = "03000000c71d8724af6e821eea82b4333bdfbd3dc9aa42031319e7869d95d3fbe8679f75" \
                    "1300000000000000747572662d7369676e65722d636f6e736f6c65" \
                    "0017160000000000" "5000000000000000" + ("00" * 32)

  def nonce_info(authority:, value:, owner: SYSTEM_OWNER, state: 1)
    data = [1, state].pack("VV") + Solana::Keypair.decode_base58(authority) +
           Solana::Keypair.decode_base58(value) + [5000].pack("Q<")
    { "value" => { "owner" => owner, "data" => [Base64.strict_encode64(data), "base64"] } }
  end

  def server = Solana::Keypair.admin.to_base58

  def vault_with(account_infos = {}, raises: false)
    client = FakeSolanaClient.new({}, account_infos: account_infos, account_info_raises: raises)
    Struct.new(:client).new(client)
  end

  test "the address is createWithSeed(server, SEED, System), byte-for-byte with web3.js" do
    assert_equal DERIVED, Solana::ConsoleNonce.address_for(BASE)
  end

  test "CreateAccountWithSeed encodes as web3.js does, the base listed once as funder" do
    ix = Solana::ConsoleNonce.create_with_seed_instruction(funder: BASE, new_account: DERIVED, lamports: 1_447_680)
    assert_equal CREATE_DATA_HEX, ix[:data].unpack1("H*")
    assert_equal [[BASE, true, true], [DERIVED, false, true]],
                 ix[:accounts].map { |a| [Solana::Keypair.encode_base58(a[:pubkey]), a[:is_signer], a[:is_writable]] }
  end

  test "ready when the derived account is an initialized nonce whose authority is the server" do
    value = Solana::Keypair.generate.to_base58
    derived = Solana::ConsoleNonce.address_for(server)
    nonce = Solana::ConsoleNonce.new(vault: vault_with({ derived => nonce_info(authority: server, value: value) }),
                                     server: server, env_pubkey: nil)

    assert nonce.ready?
    assert_equal({ pubkey: derived, authority: server }, nonce.config)
    assert_equal value, nonce.status[:value]
  end

  test "a nonce held by another authority is never used, so a rotated server key does not inherit 8K81's" do
    derived = Solana::ConsoleNonce.address_for(server)
    other = Solana::Keypair.generate.to_base58
    nonce = Solana::ConsoleNonce.new(
      vault: vault_with({ derived => nonce_info(authority: other, value: Solana::Keypair.generate.to_base58) }),
      server: server, env_pubkey: nil
    )

    # The address is taken, so it reads OCCUPIED rather than offering a
    # prepare that CreateAccountWithSeed would refuse.
    assert_equal Solana::ConsoleNonce::OCCUPIED, nonce.status[:state]
    assert_nil nonce.config
  end

  test "dust on the derived address blocks prepare with the env-var remedy, before anything is signed" do
    derived = Solana::ConsoleNonce.address_for(server)
    dust = { "value" => { "owner" => SYSTEM_OWNER, "lamports" => 1, "data" => ["", "base64"] } }
    vault, sent = sending_vault({ derived => dust })
    nonce = Solana::ConsoleNonce.new(vault: vault, server: server, env_pubkey: nil)

    assert_equal Solana::ConsoleNonce::OCCUPIED, nonce.status[:state]
    error = assert_raises(Solana::ConsoleNonce::Refused) { nonce.prepare! }
    assert_match(/SOLANA_DURABLE_NONCE_PUBKEY/, error.message)
    assert_empty sent
  end

  test "an account not owned by the System program, or not initialized, is not a nonce" do
    derived = Solana::ConsoleNonce.address_for(server)
    value = Solana::Keypair.generate.to_base58
    foreign = Solana::ConsoleNonce.new(
      vault: vault_with({ derived => nonce_info(authority: server, value: value, owner: BASE) }), server: server, env_pubkey: nil
    )
    uninit = Solana::ConsoleNonce.new(
      vault: vault_with({ derived => nonce_info(authority: server, value: value, state: 0) }), server: server, env_pubkey: nil
    )

    refute foreign.ready?
    refute uninit.ready?
  end

  test "SOLANA_DURABLE_NONCE_PUBKEY is a fallback, used only while the server is its authority" do
    env = Solana::Keypair.generate.to_base58
    value = Solana::Keypair.generate.to_base58
    ours = Solana::ConsoleNonce.new(vault: vault_with({ env => nonce_info(authority: server, value: value) }),
                                    server: server, env_pubkey: env)
    theirs = Solana::ConsoleNonce.new(
      vault: vault_with({ env => nonce_info(authority: BASE, value: value) }), server: server, env_pubkey: env
    )

    assert_equal env, ours.config[:pubkey]
    assert_nil theirs.config
  end

  test "an unreadable chain is UNREADABLE, never ready, and never raises" do
    nonce = Solana::ConsoleNonce.new(vault: vault_with(raises: true), server: server, env_pubkey: nil)
    assert_equal Solana::ConsoleNonce::UNREADABLE, nonce.status[:state]
    assert_nil nonce.config
  end

  test "no server key, no nonce" do
    nonce = Solana::ConsoleNonce.new(vault: vault_with, server: nil, env_pubkey: nil)
    assert_equal Solana::ConsoleNonce::NO_SERVER_KEY, nonce.status[:state]
  end

  # A client that records what the server sends.
  def sending_vault(account_infos = {})
    client = FakeSolanaClient.new({}, account_infos: account_infos)
    sent = []
    client.define_singleton_method(:get_latest_blockhash) { |**| "11111111111111111111111111111112" }
    client.define_singleton_method(:get_minimum_balance_for_rent_exemption) { |_size| 1_447_680 }
    client.define_singleton_method(:send_and_confirm) { |wire, **| sent << wire; "PREPARED" }
    [Struct.new(:client).new(client), sent]
  end

  test "prepare! sends ONE server-signed wire: create-with-seed then initialize, authority = server" do
    vault, sent = sending_vault
    nonce = Solana::ConsoleNonce.new(vault: vault, server: server, env_pubkey: nil)

    result = nonce.prepare!

    assert_equal "PREPARED", result[:signature]
    wire = Solana::WireMessage.parse_base64(sent.sole)
    assert_equal 1, wire.num_required_signatures, "the server is the only signer"
    assert wire.signature_valid?(0)
    assert_equal server, Solana::Keypair.encode_base58(wire.account_keys[0])
    create, init = wire.instructions
    assert_equal 3, create[:data].unpack1("V")
    assert_equal Solana::ConsoleNonce.address_for(server), Solana::Keypair.encode_base58(create[:accounts][1])
    assert_equal 6, init[:data].unpack1("V")
    assert_equal server, Solana::Keypair.encode_base58(init[:data].byteslice(4, 32)), "the server is the authority"
  end

  test "prepare! refuses when a ready nonce exists, or the chain cannot be read" do
    derived = Solana::ConsoleNonce.address_for(server)
    vault, sent = sending_vault({ derived => nonce_info(authority: server, value: Solana::Keypair.generate.to_base58) })
    assert_raises(Solana::ConsoleNonce::Refused) do
      Solana::ConsoleNonce.new(vault: vault, server: server, env_pubkey: nil).prepare!
    end
    assert_raises(Solana::ConsoleNonce::Refused) do
      Solana::ConsoleNonce.new(vault: vault_with(raises: true), server: server, env_pubkey: nil).prepare!
    end
    assert_empty sent
  end

  test "advance! sends one server-signed advanceNonceAccount" do
    derived = Solana::ConsoleNonce.address_for(server)
    vault, sent = sending_vault({ derived => nonce_info(authority: server, value: Solana::Keypair.generate.to_base58) })
    Solana::ConsoleNonce.new(vault: vault, server: server, env_pubkey: nil).advance!(derived)

    wire = Solana::WireMessage.parse_base64(sent.sole)
    ix = wire.instructions.sole
    assert_equal 4, ix[:data].unpack1("V")
    assert_equal [derived, server], [ix[:accounts][0], ix[:accounts][2]].map { |k| Solana::Keypair.encode_base58(k) }
  end

  test "advance! refuses a nonce whose ON-CHAIN authority is not this key, and sends nothing" do
    derived = Solana::ConsoleNonce.address_for(server)
    vault, sent = sending_vault({ derived => nonce_info(authority: BASE, value: Solana::Keypair.generate.to_base58) })
    assert_raises(Solana::ConsoleNonce::Refused) do
      Solana::ConsoleNonce.new(vault: vault, server: server, env_pubkey: nil).advance!(derived)
    end
    assert_empty sent
  end

  # ── void!: the only death of a nonce wire ─────────────────────────────────

  # A nonce whose value moves when the server sends an advance.
  def moving_vault(authority:, value:)
    current = value
    info = ->(_c) { nonce_info(authority: authority, value: current) }
    vault, sent = sending_vault({ Solana::ConsoleNonce.address_for(server) => info })
    vault.client.define_singleton_method(:send_and_confirm) do |wire, **|
      sent << wire
      current = Solana::Keypair.generate.to_base58
      "ADVANCED"
    end
    [vault, sent]
  end

  test "void! advances a nonce that still holds the built value, and confirms it moved" do
    value = Solana::Keypair.generate.to_base58
    vault, sent = moving_vault(authority: server, value: value)
    nonce = Solana::ConsoleNonce.new(vault: vault, server: server, env_pubkey: nil)

    assert_equal :advanced, nonce.void!(pubkey: nonce.derived_address, value: value)
    assert_equal 1, sent.length
  end

  test "void! leaves a nonce that already moved alone" do
    vault, sent = moving_vault(authority: server, value: Solana::Keypair.generate.to_base58)
    nonce = Solana::ConsoleNonce.new(vault: vault, server: server, env_pubkey: nil)

    assert_equal :already_moved, nonce.void!(pubkey: nonce.derived_address, value: Solana::Keypair.generate.to_base58)
    assert_empty sent
  end

  # THE SERVER-KEY CHANGE. A wire left on the OLD key's nonce cannot be killed
  # by the new key; void! says so instead of pretending, and sends nothing.
  test "void! reports a nonce held by another key as unvoidable, never sending" do
    value = Solana::Keypair.generate.to_base58
    vault, sent = moving_vault(authority: BASE, value: value)
    nonce = Solana::ConsoleNonce.new(vault: vault, server: server, env_pubkey: nil)

    assert_equal :unvoidable, nonce.void!(pubkey: nonce.derived_address, value: value)
    assert_empty sent
    found = nonce.outstanding([Struct.new(:parsed_metadata).new(
      { "console_nonce" => { "pubkey" => nonce.derived_address, "value" => value } }
    )])
    refute found.sole[:voidable], "the console and the ceremony show it as a hard stop"
  end

  test "void! on an unreadable chain answers :unread, never :advanced" do
    nonce = Solana::ConsoleNonce.new(vault: vault_with(raises: true), server: server, env_pubkey: nil)
    assert_equal :unread, nonce.void!(pubkey: Solana::ConsoleNonce.address_for(server), value: BASE)
  end
end
