require "test_helper"

# THE WIRE ITSELF — the tier every other entry test stops short of.
#
# Three tiers already cover the entry cosign and all three are blind to the one
# fact that decides whether a Phantom entry can complete:
#
#   * vault_cosign_validation_test feeds real builder output to the SEMANTIC
#     guard (#assert_entry_cosign_safe!) and stops there — the guard reads the
#     message, never the signature slots.
#   * contests_controller_test runs through FakeVault, whose builders return the
#     literal string "FAKE_TOKEN_TX_…" — no wire exists to cosign.
#   * e2e/free_entry_web3.spec.js sets Alpine.store('session').tokensAvailable by
#     hand, so it never reaches a server-built transaction at all.
#
# So CI was green on a rail that could not complete a single entry.
# build_enter_contest_with_token went out through #build_partial_signed, which
# signs as the admin at BUILD time and writes a real signature into slot 0.
# ContestsController#confirm_onchain_entry then hands that wire to
# Vault#cosign_and_broadcast_entry → Transaction.cosign_wire_base64(signer:
# admin), and the gem refuses to clobber a filled slot:
#
#   cosign_wire: slot 0 for 8K81w4e6… already holds a signature — refusing to clobber
#
# Money-safe (no cosign ⇒ no broadcast ⇒ no token burned, no charge) but a hard
# REGRESSION on the entry path: a Phantom wallet holding a token could enter by
# paying USDC before that wiring landed, and could not enter at all after it.
# #build_enter_contest was deliberately migrated off this exact shape for the
# Phantom path on 2026-06-05 (admin_signs: false → #build_partial_unsigned); the
# token builder never was.
#
# These tests replay the FULL Phantom-first handshake — user signs FIRST, server
# cosigns SECOND — against real builder bytes, for BOTH funding paths. The USDC
# case is the CONTROL: it exercises the identical harness against the builder
# that was already migrated, so a red here is the builder's fault and never the
# harness's.
class Solana::EntryCosignWireTest < ActiveSupport::TestCase
  SLUG = "cosign-wire-test".freeze

  # No RPC: the builders only need a blockhash. Entry txs do not use the durable
  # nonce (2026-06-11), so get_account_info is never reached.
  def fake_client
    client = Object.new
    client.define_singleton_method(:get_latest_blockhash) { |**_o| Solana::Keypair.generate.to_base58 }
    client
  end

  def vault
    @vault ||= Solana::Vault.new(client: fake_client)
  end

  # Phantom's half of the handshake: sign the EXACT message bytes and drop the
  # signature into the wallet's OWN slot, leaving every other slot untouched.
  # require_complete: false because the admin slot is still empty at this point
  # — which is the entire point of the Phantom-first order.
  def phantom_signs(serialized_tx_b64, keypair)
    Solana::Transaction.cosign_wire(Base64.decode64(serialized_tx_b64),
                                    signer: keypair, require_complete: false)
  end

  # The signature array straight off the wire: [count, [64-byte slot, …]].
  def signature_slots(wire_bytes)
    bytes = wire_bytes.b
    count, cursor = Solana::Transaction.read_compact_u16(bytes, 0)
    [count, Array.new(count) { |i| bytes.byteslice(cursor + (i * 64), 64) }]
  end

  def empty_slot?(slot)
    slot == ("\x00".b * 64)
  end

  # Signer slots map 1:1 onto the first `count` account keys, in order — so
  # "which slot is the admin's" is read off the wire rather than assumed.
  def slot_index_of(wire_bytes, pubkey_bytes)
    bytes = wire_bytes.b
    sig_count, cursor = Solana::Transaction.read_compact_u16(bytes, 0)
    message_start = cursor + (sig_count * 64)
    _account_count, acct_cursor = Solana::Transaction.read_compact_u16(bytes, message_start + 3)
    sig_count.times.find { |i| bytes.byteslice(acct_cursor + (i * 32), 32) == pubkey_bytes.b }
  end

  # --- the defect, stated directly --------------------------------------------

  test "the token builder leaves the admin slot EMPTY for the server cosign" do
    wallet = Solana::Keypair.generate
    token  = Solana::Keypair.generate.to_base58

    out = vault.build_enter_contest_with_token(wallet.to_base58, SLUG, 0, token, season_id: 1)

    wire = Base64.decode64(out[:serialized_tx])
    count, slots = signature_slots(wire)
    admin_slot = slot_index_of(wire, Solana::Keypair.admin.public_key_bytes)

    assert_equal 2, count, "token entry declares two signers: admin (payer) and the Phantom wallet"
    assert_equal 0, admin_slot, "the admin is fee payer, so it owns signature slot 0"
    assert empty_slot?(slots[admin_slot]),
           "build_enter_contest_with_token must leave the ADMIN slot empty for the server cosign " \
           "(build_partial_unsigned, Phantom-first) — a filled slot makes cosign_wire refuse to clobber " \
           "and every Phantom token entry dies at confirm"
    assert empty_slot?(slots[1]), "the Phantom wallet's slot is filled by Phantom, not by the server"
  end

  # --- the full production handshake, both funding paths -----------------------

  test "a Phantom-signed TOKEN entry wire completes the admin cosign" do
    wallet = Solana::Keypair.generate
    token  = Solana::Keypair.generate.to_base58
    entry  = FakeEntry.new(7, 0, FakeContest.new(SLUG))

    out = vault.build_enter_contest_with_token(wallet.to_base58, SLUG, 0, token, season_id: 1)

    # 1. Phantom signs first.
    user_signed = phantom_signs(out[:serialized_tx], wallet)

    # 2. The guard runs on the client's returned wire (confirm_onchain_entry
    #    validates BEFORE the admin signs anything).
    assert vault.assert_entry_cosign_safe!(Base64.strict_encode64(user_signed),
                                           entry: entry,
                                           wallet_address: wallet.to_base58,
                                           entry_token_pda: token)

    # 3. The server cosign — the exact call Vault#cosign_and_broadcast_entry
    #    makes. require_complete defaults to true, so a clean return also
    #    asserts the wire is fully signed and broadcastable (OPSEC-017).
    fully_signed = Solana::Transaction.cosign_wire(user_signed, signer: Solana::Keypair.admin)

    count, slots = signature_slots(fully_signed)
    assert_equal 2, count
    slots.each_with_index do |slot, i|
      refute empty_slot?(slot), "signature slot #{i} must be filled after the admin cosign"
    end
  end

  test "a Phantom-signed USDC entry wire completes the admin cosign (control)" do
    wallet = Solana::Keypair.generate
    entry  = FakeEntry.new(7, 0, FakeContest.new(SLUG))

    out = vault.build_enter_contest(wallet.to_base58, SLUG, 0, currency_idx: 0, season_id: 1)

    user_signed = phantom_signs(out[:serialized_tx], wallet)
    assert vault.assert_entry_cosign_safe!(Base64.strict_encode64(user_signed),
                                           entry: entry,
                                           wallet_address: wallet.to_base58)

    fully_signed = Solana::Transaction.cosign_wire(user_signed, signer: Solana::Keypair.admin)

    count, slots = signature_slots(fully_signed)
    assert_equal 2, count
    slots.each_with_index do |slot, i|
      refute empty_slot?(slot), "signature slot #{i} must be filled after the admin cosign"
    end
  end

  # The legacy server-first shape is what the token builder was stuck in. Pinning
  # it here says out loud WHY the Phantom path can't use it: cosign_wire raises
  # rather than clobber the admin signature the build already wrote.
  test "the legacy admin_signs shape is exactly what cosign_wire refuses" do
    wallet = Solana::Keypair.generate

    out = vault.build_enter_contest(wallet.to_base58, SLUG, 0, currency_idx: 0,
                                                               season_id: 1, admin_signs: true)
    user_signed = phantom_signs(out[:serialized_tx], wallet)

    err = assert_raises(RuntimeError) do
      Solana::Transaction.cosign_wire(user_signed, signer: Solana::Keypair.admin)
    end
    assert_match(/already holds a signature/, err.message)
  end

  FakeContest = Struct.new(:slug)
  FakeEntry   = Struct.new(:id, :entry_number, :contest)
end
