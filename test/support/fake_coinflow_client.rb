# Coinflow::Client stand-in for tests (FakePaypalClient sibling).
#
# Usage:
#   client = FakeCoinflowClient.new(link: "https://.../purchase-v2/X")
#   Coinflow::Client.stub :new, client do
#     # code under test
#   end
#   assert_equal 1, client.checkout_calls.length
class FakeCoinflowClient
  attr_reader :checkout_calls, :verify_calls
  attr_accessor :link, :verify_result, :raises

  def initialize(link: "https://sandbox-merchant.coinflow.cash/purchase-v2/FAKE#{SecureRandom.hex(4).upcase}",
                 verify_result: true)
    @link = link
    @verify_result = verify_result
    @raises = nil
    @checkout_calls = []
    @verify_calls = []
  end

  def create_checkout_link(user:, pack:, pack_id:, return_url:, ip:)
    raise Coinflow::Client::Error, @raises if @raises
    @checkout_calls << { user: user, pack: pack, pack_id: pack_id, return_url: return_url, ip: ip }
    @link
  end

  def verify_webhook_auth(header)
    @verify_calls << header
    @verify_result
  end
end
