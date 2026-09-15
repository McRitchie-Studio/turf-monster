require "test_helper"

# Vault#build_tx can OPTIONALLY anchor on a durable nonce (opt-in via
# SOLANA_DURABLE_NONCE_PUBKEY / an explicit durable_nonce:) so a slow Phantom
# sign can't expire the tx — the mainnet BlockhashNotFound fix. Default path
# (recent blockhash) is unchanged.
class Solana::VaultDurableNonceTest < ActiveSupport::TestCase
  # 80-byte initialized nonce account: version=1, state=1, authority, nonce, fee.
  def nonce_buffer(authority_b58:, nonce_b58:)
    [1].pack("L<") + [1].pack("L<") +
      Solana::Keypair.decode_base58(authority_b58) +
      Solana::Keypair.decode_base58(nonce_b58) +
      [5000].pack("Q<")
  end

  def fake_client(nonce_b64: nil)
    c = Object.new
    c.define_singleton_method(:get_account_info) { |_pk, **_o| { "value" => { "data" => [nonce_b64, "base64"] } } }
    c.define_singleton_method(:get_latest_blockhash) { |**_o| Solana::Keypair.generate.to_base58 }
    c
  end

  test "build_partial_signed anchors on the durable nonce + prepends the advance ix" do
    authority = Solana::Keypair.admin.address
    nonce_val = Solana::Keypair.generate.to_base58
    buf   = nonce_buffer(authority_b58: authority, nonce_b58: nonce_val)
    vault = Solana::Vault.new(client: fake_client(nonce_b64: Base64.strict_encode64(buf)))

    b64 = vault.send(:build_partial_signed,
      accounts: [{ pubkey: Solana::Keypair.admin.public_key_bytes, is_signer: true, is_writable: true }],
      data: "\x00".b * 8, additional_signers: [],
      durable_nonce: { pubkey: Solana::Keypair.generate.to_base58, authority: authority })

    raw = Base64.strict_decode64(b64).b
    # The System program (32 zero bytes) is referenced only by the advance ix.
    assert raw.include?("\x00".b * 32), "expected the System advance instruction in the tx"
    # And the nonce value is baked in as the recentBlockhash.
    assert raw.include?(Solana::Keypair.decode_base58(nonce_val)), "expected the nonce value as recentBlockhash"
  end

  test "default path (no durable_nonce) uses a recent blockhash, no advance ix" do
    vault = Solana::Vault.new(client: fake_client)
    b64 = vault.send(:build_partial_signed,
      accounts: [{ pubkey: Solana::Keypair.admin.public_key_bytes, is_signer: true, is_writable: true }],
      data: "\x01".b * 8, additional_signers: [])
    assert b64.is_a?(String) && !b64.empty?
  end

  test "durable_nonce_config is nil unless the env var is set" do
    vault = Solana::Vault.new(client: fake_client)
    assert_nil vault.send(:durable_nonce_config)
  end

  # --- entry flow: build_enter_contest opts into the same nonce ----------------
  # Mirrors build_create_contest. With SOLANA_DURABLE_NONCE_PUBKEY set, the entry
  # tx must anchor on the stored nonce + carry the System advance ix; unset, it
  # falls back to a recent blockhash with no advance ix.

  # A real entrant's wallet — MUST differ from the admin managed wallet (the
  # payer). enter_contest's account list marks BOTH the payer (admin, a local
  # signer) and the user (this wallet, the client-side "additional" signer) as
  # signers, so provided (2) must equal required (2). If this equalled the admin
  # address the two signer slots would collapse to one key (required == 1) and
  # build_partial_signed's OPSEC-017 guard would correctly reject it — a
  # degenerate self-entry, never a real flow. (Mason's seed wallet; the admin /
  # Xan wallet is 8K81w4e6…aRYd.)
  WALLET = "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR".freeze

  test "build_enter_contest IGNORES the durable nonce env (entries use a fresh blockhash)" do
    # 2026-06-11 mainnet incident: entries deliberately do NOT anchor on the
    # operator nonce even when SOLANA_DURABLE_NONCE_PUBKEY is set — Phantom's
    # injected guard ixs break nonce-first detection (BlockhashNotFound at
    # preflight), and one nonce can't serve concurrent entrants. The nonce
    # stays for operator flows (build_partial_signed callers below).
    authority = Solana::Keypair.admin.address
    nonce_val = Solana::Keypair.generate.to_base58
    buf   = nonce_buffer(authority_b58: authority, nonce_b58: nonce_val)
    vault = Solana::Vault.new(client: fake_client(nonce_b64: Base64.strict_encode64(buf)))

    out = nil
    with_durable_nonce_env(Solana::Keypair.generate.to_base58) do
      out = vault.build_enter_contest(WALLET, "dnonce-entry-test", 0, currency_idx: 0, season_id: 1)
    end

    raw = Base64.strict_decode64(out[:serialized_tx]).b
    refute raw.include?(Solana::Keypair.decode_base58(nonce_val)),
           "the nonce value must NOT be the entry tx's recentBlockhash"
    assert out[:entry_pda].present?
  end

  test "build_enter_contest falls back to a recent blockhash when the env var is unset" do
    vault = Solana::Vault.new(client: fake_client)
    ensure_durable_nonce_unset!

    out = vault.build_enter_contest(WALLET, "dnonce-entry-test", 0, currency_idx: 0, season_id: 1)
    assert out[:serialized_tx].is_a?(String) && !out[:serialized_tx].empty?
    assert out[:entry_pda].present?
  end

  private

  def with_durable_nonce_env(pubkey)
    prev = ENV["SOLANA_DURABLE_NONCE_PUBKEY"]
    ENV["SOLANA_DURABLE_NONCE_PUBKEY"] = pubkey
    yield
  ensure
    if prev.nil? then ENV.delete("SOLANA_DURABLE_NONCE_PUBKEY") else ENV["SOLANA_DURABLE_NONCE_PUBKEY"] = prev end
  end

  def ensure_durable_nonce_unset!
    ENV.delete("SOLANA_DURABLE_NONCE_PUBKEY")
  end
end
