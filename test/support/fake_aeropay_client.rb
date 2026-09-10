# Aeropay::Client stand-in for tests (FakeCoinflowClient sibling).
#
# Usage:
#   client = FakeAeropayClient.new(transaction_id: "txn_X")
#   Aeropay::Client.stub :new, client do
#     # code under test
#   end
#   assert_equal 1, client.deposit_calls.length
class FakeAeropayClient
  attr_reader :deposit_calls, :verify_calls
  attr_accessor :transaction_id, :status, :verify_result, :raises

  def initialize(transaction_id: "txn_#{SecureRandom.hex(6)}", status: "pending", verify_result: true)
    @transaction_id = transaction_id
    @status = status
    @verify_result = verify_result
    @raises = nil
    @deposit_calls = []
    @verify_calls = []
  end

  def create_deposit(user:, pack:, bank_account_id:, reference:, idempotency_key: nil)
    raise Aeropay::Client::Error, @raises if @raises
    @deposit_calls << {
      user: user, pack: pack, bank_account_id: bank_account_id,
      reference: reference, idempotency_key: idempotency_key
    }
    { "id" => @transaction_id, "status" => @status, "raw" => {} }
  end

  def verify_webhook(raw_body, signature)
    @verify_calls << [raw_body, signature]
    @verify_result
  end
end
