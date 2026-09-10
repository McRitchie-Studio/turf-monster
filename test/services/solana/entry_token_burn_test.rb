require "test_helper"

# `burn_entry_token` — the operator claw-back that voids an unspent free entry.
#
# The on-chain design this locks down, and why it is shaped this way:
#
#   * It TOMBSTONES rather than closing the account. Rails derives what a user is
#     owed from the on-chain token COUNT (admin/free_entries_controller's
#     `owed = seeds/SEEDS_PER_LEVEL - tokens.length`, and
#     Tokens::LevelUpGrant#missing_levels). Closing the PDA would drop that count,
#     so a burned token would re-read as owed and be re-minted by the next
#     "Mint all" or level-up sweep — the burn would undo itself.
#   * The tombstone rides in the HIGH BIT of the existing `source` byte, because
#     EntryTokenAccount is 124 bytes and fully packed. A real `burned` column
#     would grow the struct, and every account minted before the upgrade would
#     stop deserializing — taking enter_contest_with_token down with it for those
#     holders.
#
# That second point is what makes the Ruby side load-bearing rather than
# cosmetic: `source` off the wire is no longer a bare enum value, and a reader
# that forgets to mask turns a burned Stripe token (1 | 0x80 = 129) into a source
# no lookup table has.
class Solana::EntryTokenBurnTest < ActiveSupport::TestCase
  # No RPC. burn needs a blockhash to build and a send that swallows the wire.
  def fake_client(sink)
    client = Object.new
    client.define_singleton_method(:get_latest_blockhash) { |**_o| Solana::Keypair.generate.to_base58 }
    client.define_singleton_method(:send_and_confirm) do |wire|
      sink << wire
      "burn_sig_#{SecureRandom.hex(4)}"
    end
    client
  end

  def vault_with_sink
    sink = []
    [Solana::Vault.new(client: fake_client(sink)), sink]
  end

  # The exact 124-byte EntryTokenAccount body, in the layout decode_entry_token
  # walks. Built here rather than fetched so a decode test can express a state
  # (burned) that no fixture on any cluster currently holds.
  def encoded_account(source_byte:, consumed: false, consumed_at: nil, created_at: 1_700_000_000,
                      owner: Solana::Keypair.generate.public_key_bytes, source_ref: "operator:test:1")
    ref = source_ref.b.bytes.first(64)
    ref += [0] * (64 - ref.length)

    body = "\x00".b * 8                          # anchor discriminator (unread)
    body += owner                                 # owner: Pubkey
    body += [source_byte].pack("C")               # source: u8  (carries BURNED_FLAG)
    body += ref.pack("C*")                        # source_ref: [u8;64]
    body += [consumed ? 1 : 0].pack("C")          # consumed: bool
    body += [consumed_at ? 1 : 0].pack("C")       # consumed_at: Option tag
    body += [consumed_at.to_i].pack("Q<")         # consumed_at: i64 payload
    body += [created_at].pack("Q<")               # created_at: i64
    body += [255].pack("C")                       # bump: u8

    assert_equal Solana::Vault::ENTRY_TOKEN_LEN, body.bytesize,
      "the test's own encoder must match the on-chain layout it claims to model"

    { "pubkey" => "TokenPda11111111111111111111111111111111111",
      "account" => { "data" => [Base64.strict_encode64(body), "base64"] } }
  end

  # ── The wire ────────────────────────────────────────────────────────────

  test "burn wire carries the burn_entry_token discriminator and the ref hash" do
    vault, sink = vault_with_sink
    ref = "operator:burn-me:1"

    vault.burn_entry_token(wallet_address: Solana::Keypair.generate.to_base58, source_ref: ref)

    assert_equal 1, sink.length, "burn must send exactly one transaction"
    wire = Base64.decode64(sink.first)

    disc      = Solana::Transaction.anchor_discriminator("burn_entry_token")
    ref_hash  = Digest::SHA256.digest(vault.send(:padded_source_ref, ref))
    # The instruction data is disc(8) + source_ref_hash(32) and nothing else.
    # Asserting on the CONCATENATION, not the two halves separately, is what
    # makes this a real check: either alone could appear by coincidence in a
    # serialized message; the 40-byte pair could not.
    assert_includes wire, disc + ref_hash,
      "the wire must carry burn_entry_token's discriminator immediately followed by sha256(padded ref)"

    # And it must NOT be a mint. A copy-paste of mint_entry_token that forgot to
    # change the discriminator would still hash the right ref and still send.
    refute_includes wire, Solana::Transaction.anchor_discriminator("mint_entry_token"),
      "burn must not send mint's discriminator"
  end

  test "burn addresses the SAME PDA that minting the same source_ref creates" do
    vault, sink = vault_with_sink
    ref = "stripe:cs_test_burn:0"

    vault.burn_entry_token(wallet_address: Solana::Keypair.generate.to_base58, source_ref: ref)

    pda, _ = vault.send(:entry_token_pda, ref)
    assert_includes Base64.decode64(sink.first), pda,
      "burn must target the account mint would have created for this ref — " \
      "a different derivation burns a token that is not the one named"
  end

  test "burn refuses a source_ref that could never have been minted" do
    vault, sink = vault_with_sink
    # padded_source_ref raises past [u8;64] rather than truncating. A truncating
    # burn would aim at the PDA of a DIFFERENT, shorter ref — destroying the
    # wrong token — so this must fail before it sends anything.
    assert_raises(ArgumentError) do
      vault.burn_entry_token(wallet_address: Solana::Keypair.generate.to_base58, source_ref: "x" * 65)
    end
    assert_empty sink, "nothing may be broadcast for a ref that cannot be encoded"
  end

  test "burn invalidates the wallet's entry-token cache" do
    vault, _sink = vault_with_sink
    address = Solana::Keypair.generate.to_base58
    key = Solana::Vault.entry_tokens_cache_key(address)

    Rails.cache.write(key, [{ consumed: false }])
    vault.burn_entry_token(wallet_address: address, source_ref: "operator:cache:1")

    assert_nil Rails.cache.read(key),
      "a stale list would keep offering a Burn on a token that is already gone"
  end

  # ── The decode ──────────────────────────────────────────────────────────

  test "decode masks the burn flag out of source and reports burned" do
    vault, _ = vault_with_sink
    stripe = Solana::Vault::ENTRY_TOKEN_SOURCE[:stripe]
    burned_byte = stripe | Solana::Vault::ENTRY_TOKEN_BURNED_FLAG

    token = vault.send(:decode_entry_token,
                       encoded_account(source_byte: burned_byte, consumed: true, consumed_at: 1_700_000_500))

    assert_equal stripe, token[:source],
      "provenance must survive the burn — a clawed-back Stripe token is still a Stripe token"
    assert token[:burned], "the high bit must surface as burned: true"
    assert token[:consumed], "a burn sets consumed — that is what blocks the spend on chain"
    assert_equal 1_700_000_500, token[:consumed_at]
  end

  test "decode reports burned false for every un-burned source, including unminted rails" do
    vault, _ = vault_with_sink

    Solana::Vault::ENTRY_TOKEN_SOURCE.each do |rail, byte|
      token = vault.send(:decode_entry_token, encoded_account(source_byte: byte))
      assert_equal byte, token[:source], "#{rail} must decode to its own source byte untouched"
      refute token[:burned], "#{rail} was never burned — the flag must not read as set"
    end
  end

  test "a SPENT token is not reported as burned" do
    vault, _ = vault_with_sink
    # The distinction the flag exists for. Both states are consumed: true, so
    # `consumed` alone cannot tell an operator claw-back from a real redemption,
    # and a UI reading only `consumed` would label them identically.
    spent = vault.send(:decode_entry_token,
                       encoded_account(source_byte: Solana::Vault::ENTRY_TOKEN_SOURCE[:operator],
                                       consumed: true, consumed_at: 1_700_000_400))

    assert spent[:consumed], "a spent token is consumed"
    refute spent[:burned], "a token spent on a real entry must never read as burned"
  end

  test "the burn flag cannot collide with any source byte, present or future" do
    # The flag lives in `source`'s spare high bit, which is only spare while every
    # provenance value stays under 0x80. Adding a 128th rail would silently make
    # every token of that rail read as burned.
    Solana::Vault::ENTRY_TOKEN_SOURCE.each do |rail, byte|
      assert_equal 0, byte & Solana::Vault::ENTRY_TOKEN_BURNED_FLAG,
        "source byte for #{rail} (#{byte}) sets the burn flag — pick a value under " \
        "#{Solana::Vault::ENTRY_TOKEN_BURNED_FLAG} or the tombstone stops meaning anything"
    end
    assert_equal 0xff,
      Solana::Vault::ENTRY_TOKEN_BURNED_FLAG | Solana::Vault::ENTRY_TOKEN_SOURCE_MASK,
      "flag and mask must partition the byte with no gap and no overlap"
    assert_equal 0,
      Solana::Vault::ENTRY_TOKEN_BURNED_FLAG & Solana::Vault::ENTRY_TOKEN_SOURCE_MASK
  end
end
