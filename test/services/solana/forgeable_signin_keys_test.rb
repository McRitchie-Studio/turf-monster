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

  # Matching on decoded bytes, not only on the listed spelling, is what makes
  # the denylist hold for a string the list does not name.
  test "a different spelling of a listed key is forgeable too" do
    spelling = "1" * 31
    assert_equal ("\x00" * 32).b, Solana::Keypair.decode_base58(spelling),
                 "control: this spelling must decode to a listed key's bytes"
    assert_not Solana::ForgeableSigninKeys::ENCODINGS.key?(spelling), "control: the list must not name it"

    assert Solana::ForgeableSigninKeys.forgeable?(spelling)
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
