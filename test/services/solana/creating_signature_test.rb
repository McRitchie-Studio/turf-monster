require "test_helper"

# [unit] A versioned transaction (getTransaction -32015) is passed over; any other RPC error raises.
class Solana::CreatingSignatureTest < ActiveSupport::TestCase
  class Client < FakeSolanaClient
    def get_transaction(signature, **)
      raise Solana::Client::RpcError.new("refused", code: signature == "v0" ? -32_015 : -32_005) if signature != "entry"
      super
    end
  end
  test "a versioned transaction sent before the entry does not hide the entry" do
    entry = ChainFixtures.program_transaction("enter_contest", signer: "wallet", account: "pda")
    find = lambda do |old|
      client = Client.new({}, signatures: { "pda" => [{ "signature" => "entry" }, { "signature" => old }] }, transactions: { "entry" => entry })
      Solana::CreatingSignature.find("pda", instructions: %w[enter_contest], signer: "wallet", client: client)
    end
    assert_equal "entry", find.call("v0")
    assert_raises(Solana::Client::RpcError) { find.call("down") }
  end
end
