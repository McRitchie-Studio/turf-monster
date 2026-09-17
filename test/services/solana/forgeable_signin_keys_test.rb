require "test_helper"

# Solana::ForgeableSigninKeys is a STOPGAP denylist (see the module). These tests
# do not take its list on trust: they derive the complete set of small-order
# Ed25519 public-key encodings from the curve itself and require the module to
# carry exactly that set, no more and no less.
class Solana::ForgeableSigninKeysTest < ActiveSupport::TestCase
  P = 2**255 - 19
  D = (-121_665 * 121_666.pow(P - 2, P)) % P
  IDENTITY = [0, 1].freeze

  # One order-8 point, as its canonical encoding. Everything else is derived
  # from it, and the derivation checks the order, so a wrong constant here
  # fails loudly rather than producing a smaller set.
  ORDER_EIGHT = "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a".freeze

  def le_int(bytes) = bytes.unpack("C*").each_with_index.sum { |b, i| b << (8 * i) }
  def le_bytes(int) = Array.new(32) { |i| (int >> (8 * i)) & 0xff }.pack("C*").b

  def add((x1, y1), (x2, y2))
    t = D * x1 * x2 * y1 * y2 % P
    [(x1 * y2 + x2 * y1) * (1 + t).pow(P - 2, P) % P, (y1 * y2 + x1 * x2) * (1 - t).pow(P - 2, P) % P]
  end

  def times(point, n) = (n - 1).times.reduce(point) { |acc, _| add(acc, point) }

  # Decodes the way the ref10 code inside the ed25519 gem does: y is NOT required
  # to be below p, and a zero x with its sign bit set is not rejected.
  def decode_point(bytes)
    n = le_int(bytes)
    sign = n >> 255
    y = (n & ((1 << 255) - 1)) % P
    xx = (y * y - 1) * (D * y * y + 1).pow(P - 2, P) % P
    x = xx.pow((P + 3) / 8, P)
    x = x * 2.pow((P - 1) / 4, P) % P unless (x * x - xx) % P == 0
    return nil unless (x * x - xx) % P == 0

    x = P - x if x != 0 && (x & 1) != sign
    [x, y]
  end

  # Every 32-byte string that decodes to one of the eight small-order points.
  def derived_small_order_encodings
    generator = decode_point([ORDER_EIGHT].pack("H*"))
    assert_equal IDENTITY, times(generator, 8), "control: the generator must have order dividing 8"
    assert_not_equal IDENTITY, times(generator, 4), "control: the generator must have order exactly 8"

    points = (1..8).map { |k| times(generator, k) }
    assert_equal 8, points.uniq.size, "control: an order-8 generator yields eight distinct points"

    points.flat_map do |x, y|
      ys = [y]
      ys << y + P if y + P < 2**255
      signs = x.zero? ? [0, 1] : [x & 1]
      ys.product(signs).map { |yy, s| le_bytes(yy | (s << 255)) }
    end.uniq
  end

  test "the module lists exactly the small-order encodings the curve admits" do
    derived = derived_small_order_encodings
    assert_equal 14, derived.size, "eight points, plus six encodings the decoder also accepts"
    derived.each { |bytes| assert_equal IDENTITY, times(decode_point(bytes), 8) }

    listed = Solana::ForgeableSigninKeys::ENCODINGS.values.map { |hex| [hex].pack("H*").b }
    assert_equal derived.sort, listed.sort
  end

  test "every listed address is the base58 spelling of its bytes" do
    Solana::ForgeableSigninKeys::ENCODINGS.each do |address, hex|
      assert_equal address, Solana::Keypair.encode_base58([hex].pack("H*")), "table drift at #{address}"
    end
  end

  test "each listed address is forgeable" do
    assert_equal 14, Solana::ForgeableSigninKeys::ENCODINGS.size
    Solana::ForgeableSigninKeys::ENCODINGS.each_key do |address|
      assert Solana::ForgeableSigninKeys.forgeable?(address), "#{address} must be refused"
    end
  end

  test "every listed address decodes back to its bytes" do
    Solana::ForgeableSigninKeys::ENCODINGS.each do |address, hex|
      assert_equal [hex].pack("H*").b, Solana::Keypair.decode_base58(address).b, "decoder drift at #{address}"
    end
  end

  # forgeable? also matches on DECODED bytes, so a spelling the list does not
  # name is still refused if the decoder maps it onto a listed key. Before
  # 0.12.0, solana-studio did exactly that: "1" * 31 decoded to the all-zero key.
  # 0.12.0 decodes one-to-one, so no real string reaches this arm any more; the
  # stub stands in for an aliasing decoder, once for each listed key.
  test "the bytes match refuses an unlisted spelling that decodes to any listed key" do
    spelling = Solana::Keypair.encode_base58(Ed25519::SigningKey.generate.verify_key.to_bytes)
    assert_not Solana::ForgeableSigninKeys::ENCODINGS.key?(spelling), "control: the list must not name it"
    assert_not Solana::ForgeableSigninKeys.forgeable?(spelling), "control: with the real decoder it is a real wallet"
    assert_equal 14, Solana::ForgeableSigninKeys::KEY_BYTES.size

    Solana::ForgeableSigninKeys::KEY_BYTES.each do |bytes|
      Solana::Keypair.stub(:decode_base58, ->(_) { bytes }) do
        assert Solana::ForgeableSigninKeys.forgeable?(spelling), "#{bytes.unpack1('H*')} must be matched on bytes"
      end
    end
  end

  # The alias the old decoder had. solana-studio 0.11.0 decoded "1" * 31 to the
  # 32-byte all-zero key, and only the bytes match caught it. 0.12.0 decodes it
  # to 31 bytes: not a listed key, and not a key at all, so verify! refuses it on
  # length before any signature check runs.
  test "the all-ones alias no longer decodes to a key and is refused on length" do
    spelling = "1" * 31
    assert_not Solana::ForgeableSigninKeys::ENCODINGS.key?(spelling), "control: the list must not name it"
    assert_equal ("\x00" * 31).b, Solana::Keypair.decode_base58(spelling).b,
                 "31 ones must decode to 31 zero bytes, not the 32-byte zero key"

    error = assert_raises(Solana::AuthVerifier::VerificationError) do
      Solana::AuthVerifier.verify!(
        message: "www.example.com wants you to sign in with your Solana account:\n#{spelling}\n\nNonce: n",
        signature_b58: Solana::Keypair.encode_base58(("\x01" * 64).b),
        pubkey_b58: spelling, expected_host: "www.example.com", stored_nonce: "n"
      )
    end
    assert_equal "Public key must be 32 bytes, got 31", error.message
  end

  test "a real wallet address is not forgeable" do
    20.times do
      address = Solana::Keypair.encode_base58(Ed25519::SigningKey.generate.verify_key.to_bytes)
      assert_not Solana::ForgeableSigninKeys.forgeable?(address), address
    end
  end

  test "garbage is not forgeable and does not raise" do
    [nil, "", "not base58 0OIl", "x" * 500, 42].each do |input|
      assert_not Solana::ForgeableSigninKeys.forgeable?(input), input.inspect
    end
  end

  test "refuse! returns a real address untouched" do
    address = Solana::Keypair.encode_base58(Ed25519::SigningKey.generate.verify_key.to_bytes)
    assert_no_difference "ErrorLog.count" do
      assert_equal address, Solana::ForgeableSigninKeys.refuse!(address, context: "unit")
    end
  end

  test "refuse! raises the generic verification error and records the attempt" do
    address = Solana::ForgeableSigninKeys::ENCODINGS.keys.first

    error = assert_difference "ErrorLog.count", 1 do
      assert_raises(Solana::AuthVerifier::VerificationError) do
        Solana::ForgeableSigninKeys.refuse!(address, context: "unit")
      end
    end

    assert_equal Solana::ForgeableSigninKeys::REFUSAL_MESSAGE, error.message
    log = ErrorLog.order(:id).last
    assert_includes log.message, address
    assert_includes log.inspect_field, "Solana::ForgeableSigninKeys::Refused"
  end

  test "a failure to record never lets the key through" do
    address = Solana::ForgeableSigninKeys::ENCODINGS.keys.first

    ErrorLog.stub(:capture!, ->(*) { raise ActiveRecord::ConnectionNotEstablished }) do
      assert_raises(Solana::AuthVerifier::VerificationError) do
        Solana::ForgeableSigninKeys.refuse!(address, context: "unit")
      end
    end
  end
end
