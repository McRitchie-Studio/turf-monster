require "test_helper"

# v0.19 (Lazarus audit #9): the turf-vault program seeds the EntryTokenAccount
# PDA on sha256 of `source_ref` zero-padded to [u8;64], and the mint instruction
# asserts the passed `source_ref_hash` equals that. Ruby (Solana::Vault) MUST
# hash the SAME 64-byte buffer or it derives the wrong address / the on-chain
# assert (6038) rejects the mint. This test locks that hash-input contract; the
# live Ruby==program equality is exercised by the devnet smoke test.
class Solana::EntryTokenPdaTest < ActiveSupport::TestCase
  setup { @vault = Solana::Vault.new }

  test "seed hash is sha256 of the 64-byte zero-padded source_ref" do
    ref = "stripe:cs_test_abc123:0"
    padded = ref.b.bytes.first(64)
    padded += [0] * (64 - padded.length)
    expected = Digest::SHA256.digest(padded.pack("C*"))

    assert_equal 64, padded.length
    assert_equal 32, @vault.send(:entry_token_seed_hash, ref).bytesize
    assert_equal expected, @vault.send(:entry_token_seed_hash, ref),
      "Ruby must hash the exact 64-byte buffer the program hashes"
  end

  # Regression (Coinflow rail): mint_entry_token does
  # `ENTRY_TOKEN_SOURCE.fetch(source)` on the Symbol source it receives from
  # TokenPurchaseJob (`purchase_type.to_sym`). A rail whose purchase_type has no
  # entry raises `KeyError: key not found` at mint time — invisible to the
  # job/webhook suites because FakeVault stubs mint_entry_token. Every fiat rail
  # that reaches TokenPurchaseJob MUST have a distinct source byte here.
  test "every fiat rail's purchase_type maps to a distinct entry-token source byte" do
    %i[stripe paypal coinflow aeropay].each do |rail|
      assert Solana::Vault::ENTRY_TOKEN_SOURCE.key?(rail),
        "ENTRY_TOKEN_SOURCE missing #{rail} — mint_entry_token(source: #{rail.inspect}) would KeyError"
    end
    bytes = %i[operator stripe moonpay paypal coinflow aeropay].map { |k| Solana::Vault::ENTRY_TOKEN_SOURCE[k] }
    assert_equal bytes.length, bytes.uniq.length, "each rail's source byte must be distinct for on-chain forensics"
  end

  test "padded_source_ref pads short refs to 64 and RAISES on > 64 (no silent truncation)" do
    assert_equal 64, @vault.send(:padded_source_ref, "short").bytesize
    assert_equal 64, @vault.send(:padded_source_ref, "x" * 64).bytesize, "exactly 64 is allowed"
    # Regression (TokenPurchaseJob source_ref collision): a > 64-byte ref used to
    # be silently truncated, so multi-token purchases ("...:0"/"...:1"/"...:2")
    # all hashed to ONE PDA and collided on init (custom program error 0x0).
    # It must now fail loud rather than truncate.
    err = assert_raises(ArgumentError) { @vault.send(:padded_source_ref, "x" * 65) }
    assert_match(/exceeds the on-chain \[u8;64\] limit/, err.message)
    assert_raises(ArgumentError) { @vault.send(:entry_token_seed_hash, "x" * 200) }
  end

  test "distinct multi-token source_refs derive DISTINCT PDAs (collision regression)" do
    # The fixed TokenPurchaseJob source_ref shape: stripe:<purchase_id>:<index>.
    refs  = (0..2).map { |i| "stripe:37:#{i}" }
    refs.each { |r| assert_operator r.bytesize, :<=, 64, "ref must fit [u8;64]: #{r}" }
    pdas = refs.map { |r| @vault.send(:entry_token_pda, r).first }
    assert_equal 3, pdas.uniq.length, "each token in a trio must derive a unique PDA"
  end

  test "entry_token_pda is deterministic per source_ref and unique across refs" do
    a1, b1 = @vault.send(:entry_token_pda, "ref-A")
    a2, _  = @vault.send(:entry_token_pda, "ref-A")
    other, = @vault.send(:entry_token_pda, "ref-B")

    assert_equal a1, a2, "same source_ref must derive the same PDA"
    assert_not_equal a1, other, "different source_ref must derive a different PDA"
    assert_equal 32, a1.bytesize, "PDA pubkey is 32 bytes"
    assert_includes 0..255, b1, "bump is a u8"
  end

  test "entry_token_pda is seeded on [b'entry_token', seed_hash] under the vault program id" do
    ref = "operator:Wallet111:deadbeef"
    pda, = @vault.send(:entry_token_pda, ref)
    program_id = @vault.instance_variable_get(:@program_id)
    expected, = Solana::Transaction.find_pda(
      ["entry_token".b, @vault.send(:entry_token_seed_hash, ref)],
      program_id
    )
    assert_equal expected, pda
  end

  # --- operator-mint source_ref (Solana::Vault.operator_source_ref) ---
  # Regression (prod v119 caution): the /admin/free_entries operator mint built
  # "operator:#{wallet}:#{nonce}" — a ~44-char base58 address pushed it to ~86
  # bytes, so padded_source_ref RAISED and zero owed free entries minted.
  # FakeVault masks this (it records the ref, never packs it to [u8;64]), so
  # these MUST go through the real packer to be meaningful.

  test "operator_source_ref fits the on-chain [u8;64] limit (even at max bigint id)" do
    [1, 12_345, 9_223_372_036_854_775_807].each do |id|
      user = Struct.new(:id).new(id)
      ref  = Solana::Vault.operator_source_ref(user)
      assert_operator ref.bytesize, :<=, 64,
        "operator source_ref must fit [u8;64]: #{ref.inspect} (#{ref.bytesize}B)"
      assert_nothing_raised { @vault.send(:padded_source_ref, ref) }
    end
  end

  test "operator_source_ref is globally unique per mint" do
    user = Struct.new(:id).new(42)
    refs = Array.new(50) { Solana::Vault.operator_source_ref(user) }
    assert_equal refs.length, refs.uniq.length,
      "each operator mint needs a distinct source_ref so it derives a unique PDA"
  end

  test "the OLD wallet-keyed operator ref WOULD overflow [u8;64] (guards the regression)" do
    # The exact shape that broke prod: "operator:" + 44-char address + ":" + 32-char nonce.
    bad = "operator:#{"A" * 44}:#{SecureRandom.hex(16)}"
    assert_operator bad.bytesize, :>, 64,
      "sanity: the old wallet-keyed format is the >64-byte shape that regressed"
    assert_raises(ArgumentError) { @vault.send(:padded_source_ref, bad) }
  end
end
