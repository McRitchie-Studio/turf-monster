require "test_helper"

# [unit] Solana::Vault#read_prize_pool_balance decodes the LIVE balance of a
# contest's prize-pool SPL token account, distinguishes a closed account (nil)
# from an empty one (0), and raises rather than guessing on a malformed or
# unreadable account. Contests::CancellationReconciler leans on all three.
class Solana::VaultPrizePoolBalanceTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :asked

    def initialize(value) = (@value = value; @asked = [])

    def get_account_info(pubkey, **)
      @asked << pubkey
      raise "rpc down" if @value == :raise

      { "value" => @value }
    end
  end

  def token_account(amount, bytes: 165)
    data = ("\x01" * 64).b + [amount].pack("Q<") + ("\x00" * [bytes - 72, 0].max).b
    { "data" => [Base64.strict_encode64(data[0, bytes]), "base64"] }
  end

  def balance(value, slug: "world-cup-week-1-turf-totals")
    client = FakeClient.new(value)
    result = Solana::Vault.new(client: client).read_prize_pool_balance(slug)
    [result, client]
  end

  test "reads the u64 amount at offset 64 of the prize-pool PDA" do
    result, client = balance(token_account(500_000_000))

    assert_equal 500_000_000, result
    vault = Solana::Vault.new(client: client)
    assert_equal [Solana::Keypair.encode_base58(vault.prize_pool_pda("world-cup-week-1-turf-totals")[0])], client.asked
  end

  test "an emptied pool reads 0, not nil" do
    assert_equal 0, balance(token_account(0)).first
  end

  test "a closed pool account reads nil" do
    assert_nil balance(nil).first
  end

  test "a short account raises instead of reading a balance out of thin air" do
    assert_raises(RuntimeError) { balance(token_account(0, bytes: 40)) }
  end

  test "an RPC failure propagates" do
    assert_raises(RuntimeError) { balance(:raise) }
  end
end
