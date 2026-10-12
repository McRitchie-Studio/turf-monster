require "test_helper"

# [unit] Solana::SignerRoster — the committed public roster parses, and a
# secret-shaped value is refused by shape, never echoed.
class Solana::SignerRosterTest < ActiveSupport::TestCase
  def doc(address, holder: "alex")
    { "keys" => [{ "address" => address, "name" => "Probe", "holder" => holder,
                   "signs_in" => "phantom", "clusters" => ["devnet"] }] }
  end

  test "the committed roster parses, and every address is a 32-byte public key" do
    roster = Solana::SignerRoster.load
    assert roster.entries.length >= 8
    roster.entries.each do |entry|
      assert_equal 32, Solana::SignerIsolation.decode_base58(entry.address).bytesize, entry.name
    end
  end

  test "Mr. McRitchie's three accounts are the only Phantom-asked keys" do
    roster = Solana::SignerRoster.load
    assert_equal %w[7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr
                    9gACbzsCLmkYF9Yx1EBGmwMvvyfuTquJ6qs8QsoQvHXf
                    3Qj4v9qjhXgkru6zCRCErRVhy8Q6qU3NrNpvpXLTZboA].sort,
                 roster.alex_addresses.sort
  end

  test "a secret key in the roster refuses the whole file without echoing it" do
    secret = Solana::Keypair.encode_base58(Solana::Keypair.generate.to_bytes)
    error = assert_raises(Solana::SignerRoster::InvalidRoster) { Solana::SignerRoster.new(doc(secret)) }
    assert_match(/SECRET/, error.message)
    refute_includes error.message, secret
  end

  test "a non-base58 or short value is refused" do
    assert_raises(Solana::SignerRoster::InvalidRoster) { Solana::SignerRoster.new(doc("0OIl")) }
    assert_raises(Solana::SignerRoster::InvalidRoster) { Solana::SignerRoster.new(doc("7ZDJp7FU")) }
  end

  test "the zero key and an unknown holder are refused" do
    assert_raises(Solana::SignerRoster::InvalidRoster) { Solana::SignerRoster.new(doc(Solana::SignerRotation::EMPTY)) }
    assert_raises(Solana::SignerRoster::InvalidRoster) do
      Solana::SignerRoster.new(doc("7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr", holder: "mason"))
    end
  end

  test "a duplicated address is refused" do
    row = doc("7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr")["keys"].first
    assert_raises(Solana::SignerRoster::InvalidRoster) { Solana::SignerRoster.new("keys" => [row, row]) }
  end
end
