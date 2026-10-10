require "test_helper"
require "minitest/mock"

# [unit] THE NONCE-ANCHORED SETTLE WIRE (Solana::Vault#build_settle_contest
# with `durable_nonce:`), and the blockhash wire it leaves unchanged.
#
# Only the RPC is stood in for: a fixed recent blockhash and a fixed nonce
# account. The admin key is the test seed, so every signature is deterministic
# and a wire can be pinned by its digest.
class SettleNonceWireTest < ActiveSupport::TestCase
  include SettleNonceFixture

  # SHA-256 of the blockhash settle wire for SETTLEMENTS, built from this
  # fixture on origin/accepted 013595f8 (before durable_nonce: existed). The
  # default path must produce these bytes exactly.
  DEFAULT_WIRE_SHA256 = {
    "v0.25" => "a4a9ea7fa54a180f0f275537ead0afd639a06a86f2fa7104f91a363b8c72861e",
    "v0.26" => "2c4332786cdb11f82b2d0697deb5c486c02cca5d6647319f39b69b7b1fbd0608"
  }.freeze

  # ── the nonce-anchored wire ──────────────────────────────────────────────

  [false, true].each do |governance|
    label = governance ? "v0.26" : "v0.25"

    test "instruction 0 is advanceNonceAccount on the nonce account, signed by the cosigner (#{label})" do
      wire = parse(build(governance: governance, nonce: true))
      advance = wire.instructions.first

      assert_equal Solana::Transaction::SYSTEM_PROGRAM_ID.b, advance[:program_id]
      assert_equal ADVANCE_NONCE, advance[:data]
      assert_equal [NONCE_ACCOUNT, "SysvarRecentB1ockHashes11111111111111111111", COSIGNER.to_base58],
                   advance[:accounts].map { |a| key(a) }
      assert wire.writable?(Solana::Keypair.decode_base58(NONCE_ACCOUNT)), "the advance writes the nonce account"
      assert wire.signer?(COSIGNER.public_key_bytes), "the nonce authority holds a signer slot"
    end

    test "the recent blockhash is the nonce value, not the cluster's blockhash (#{label})" do
      result = build(governance: governance, nonce: true)

      assert_equal NONCE_VALUE, parse(result).recent_blockhash_base58
      assert_equal NONCE_VALUE, result.fetch(:nonce_value)
    end

    test "the settle follows the advance, the admin has signed and the cosigners have not (#{label})" do
      wire = parse(build(governance: governance, nonce: true))

      assert_equal 3, wire.instructions.size
      assert_equal Solana::Config::PROGRAM_ID, key(wire.instructions.last[:program_id])
      assert_equal Solana::Transaction.anchor_discriminator("settle_contest"), wire.instructions.last[:data].byteslice(0, 8)
      assert_equal Solana::Keypair.admin.public_key_bytes, wire.fee_payer
      assert wire.signature_valid?(0), "the server signed as admin"
      expected = [Solana::Keypair.admin.to_base58, COSIGNER.to_base58, *(governance ? [THIRD.to_base58] : [])]
      assert_equal expected.sort, wire.signer_keys.map { |k| key(k) }.sort
      (1...wire.num_required_signatures).each { |i| assert wire.signature_slot_empty?(i), "slot #{i} waits for the CLI" }
    end
  end

  test "the admin may be the nonce authority; it adds no slot" do
    wire = parse(build(nonce: true, authority: Solana::Keypair.admin.to_base58))

    assert_equal 2, wire.num_required_signatures
    assert_equal Solana::Keypair.admin.public_key_bytes, wire.instructions.first[:accounts].last
  end

  test "an authority that does not sign the settle is refused before anything is built" do
    stranger = Solana::Keypair.from_bytes(Digest::SHA256.digest("stranger")).to_base58

    error = assert_raises(ArgumentError) { build(nonce: true, authority: stranger) }
    assert_match(/nonce authority #{stranger} is not a signer/, error.message)
  end

  # ── the default wire is unchanged ────────────────────────────────────────

  [false, true].each do |governance|
    label = governance ? "v0.26" : "v0.25"

    test "the blockhash settle wire is byte for byte what origin/accepted built (#{label})" do
      result = build(governance: governance)
      wire = parse(result)

      assert_equal BLOCKHASH, wire.recent_blockhash_base58
      refute_equal ADVANCE_NONCE, wire.instructions.first[:data]
      refute result.key?(:nonce_value)
      assert_equal DEFAULT_WIRE_SHA256.fetch(label), Digest::SHA256.hexdigest(Base64.strict_decode64(result[:serialized_tx]))
    end
  end

  # ── the packet limit counts the advance ──────────────────────────────────
  #
  # The advance costs 106 bytes (nonce account, RecentBlockhashes sysvar,
  # System Program, the instruction). On v0.25 four paid entries still fit; on
  # v0.26 three fit and four are refused, so a four-place v0.26 settle cannot
  # take the nonce path in one legacy transaction.

  def paid(count)
    (1..count).map do |i|
      { wallet: Solana::Keypair.from_bytes(Digest::SHA256.digest("packet winner #{i}")).to_base58, entry_num: 1, rank: i, payout: 1_000_000 }
    end
  end

  def nonce_settle(settlements, governance:)
    Solana::Config.stub(:governance?, governance) do
      vault.build_settle_contest("settle-nonce-contest", settlements, cosigner_pubkey: COSIGNER.to_base58,
                                 extra_cosigners: governance ? [THIRD.to_base58] : [], durable_nonce: durable_nonce)
    end
  end

  test "nonce-anchored: four paid entries fit on v0.25" do
    assert_operator Base64.decode64(nonce_settle(paid(4), governance: false)[:serialized_tx]).bytesize, :<=, Solana::Vault::PACKET_DATA_SIZE
  end

  test "nonce-anchored: three paid entries fit on v0.26 and four are refused before anything is queued" do
    assert_operator Base64.decode64(nonce_settle(paid(3), governance: true)[:serialized_tx]).bytesize, :<=, Solana::Vault::PACKET_DATA_SIZE

    error = assert_raises(Solana::Vault::SettleTooLargeError) { nonce_settle(paid(4), governance: true) }
    assert_match(/4 paid entries serializes to 1309 bytes/, error.message)
  end
end
