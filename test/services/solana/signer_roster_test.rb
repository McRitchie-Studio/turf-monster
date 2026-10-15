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

  # Alex, 2026-10-15: his wallets in this order, and the roster's `priority`
  # is the one place that says so (the co-sign card and the signer console
  # both read it).
  test "the committed roster ranks his wallets 7ZDJ, 3Qj4, 9gAC" do
    roster = Solana::SignerRoster.load
    assert_equal %w[7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr
                    3Qj4v9qjhXgkru6zCRCErRVhy8Q6qU3NrNpvpXLTZboA
                    9gACbzsCLmkYF9Yx1EBGmwMvvyfuTquJ6qs8QsoQvHXf],
                 roster.operator_priority
  end

  test "no agent-held key in the committed roster carries a priority" do
    Solana::SignerRoster.load.entries.reject(&:alex?).each do |entry|
      assert_nil entry.priority, "#{entry.name} is an agent key and must never rank as a default"
    end
  end

  test "mainnet's seated set reorders with his wallets first and agent keys last" do
    roster = Solana::SignerRoster.load
    seated = %w[3LTLPG1s952sdNatZWtnfM7r9F3ivWSnPSqfhQLBepJ9 7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr
                4S39sKHHPV8GPjUif9noN9gdsAFGs9WASuGxs7B9s5CY 9gACbzsCLmkYF9Yx1EBGmwMvvyfuTquJ6qs8QsoQvHXf
                3Qj4v9qjhXgkru6zCRCErRVhy8Q6qU3NrNpvpXLTZboA]
    assert_equal %w[7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr 3Qj4v9qjhXgkru6zCRCErRVhy8Q6qU3NrNpvpXLTZboA
                    9gACbzsCLmkYF9Yx1EBGmwMvvyfuTquJ6qs8QsoQvHXf 3LTLPG1s952sdNatZWtnfM7r9F3ivWSnPSqfhQLBepJ9
                    4S39sKHHPV8GPjUif9noN9gdsAFGs9WASuGxs7B9s5CY],
                 roster.by_operator_priority(seated)
    refute roster.operator?("3LTLPG1s952sdNatZWtnfM7r9F3ivWSnPSqfhQLBepJ9")
    refute roster.operator?("4S39sKHHPV8GPjUif9noN9gdsAFGs9WASuGxs7B9s5CY")
    refute roster.operator?(Solana::Keypair.generate.address), "an unknown key is nobody's"
  end

  test "an unranked alex key sorts after ranked ones, in file order" do
    a, b, c = Array.new(3) { Solana::Keypair.generate.address }
    roster = Solana::SignerRoster.new("keys" => [
      { "address" => a, "name" => "A", "holder" => "alex", "signs_in" => "phantom", "clusters" => [] },
      { "address" => b, "name" => "B", "holder" => "alex", "signs_in" => "phantom", "clusters" => [], "priority" => 1 },
      { "address" => c, "name" => "C", "holder" => "alex", "signs_in" => "phantom", "clusters" => [] }
    ])
    assert_equal [b, a, c], roster.operator_priority
  end

  test "a priority on an agent key, a repeated priority, or a non-integer is refused" do
    agent = doc("7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr", holder: "agent")
    agent["keys"].first["priority"] = 1
    error = assert_raises(Solana::SignerRoster::InvalidRoster) { Solana::SignerRoster.new(agent) }
    assert_match(/only an `alex` key/, error.message)

    rows = [Solana::Keypair.generate.address, Solana::Keypair.generate.address].map do |address|
      doc(address)["keys"].first.merge("priority" => 1)
    end
    error = assert_raises(Solana::SignerRoster::InvalidRoster) { Solana::SignerRoster.new("keys" => rows) }
    assert_match(/priority 1 to more than one key/, error.message)

    bad = doc(Solana::Keypair.generate.address)
    bad["keys"].first["priority"] = "1"
    assert_raises(Solana::SignerRoster::InvalidRoster) { Solana::SignerRoster.new(bad) }
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
