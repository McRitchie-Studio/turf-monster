require "test_helper"

# [unit] Entries::PaymentCopy: how a failure's text is read. The shapes are the
# RPC's own: `custom program error: 0x…` from a simulation, and
# `{"InstructionError"=>[n, {"Custom"=>…}]}` from a wire the cluster processed.
class Entries::PaymentCopyTest < ActiveSupport::TestCase
  SIM = "Transaction simulation failed: Error processing Instruction 0: ".freeze

  def rpc(message) = Solana::Client::RpcError.new(message)
  def landed(code) = rpc(%(Transaction failed: {"InstructionError"=>[0, {"Custom"=>#{code}}]}))
  def code(error, **context) = Entries::PaymentCopy.code_for(error, sent: true, **context)

  TICKET_EXISTS = {
    "simulation, hex" => "#{SIM}custom program error: 0x0",
    "landed, decimal" => %(Transaction failed: {"InstructionError"=>[0, {"Custom"=>0}]}),
    "landed, behind an injected instruction" => %(Transaction failed: {"InstructionError"=>[2, {"Custom"=>0}]}),
    "the log line" => "#{SIM}Allocate: account already in use"
  }.freeze

  TICKET_EXISTS.each do |shape, message|
    test "already-in-use is never read as a refusal: #{shape}" do
      error = rpc(message)

      assert Entries::PaymentCopy.ticket_exists?(error)
      refute Entries::PaymentCopy.chain_refusal?(error), "this is what the entry's own ticket looks like once it exists"
    end
  end

  test "CONTROL: every other program error in the same two shapes IS a refusal, and 0x10 or Custom=>10 is not 0" do
    [rpc("#{SIM}custom program error: 0x1"), rpc("#{SIM}custom program error: 0x1774"), landed(6004), landed(1),
     rpc("#{SIM}custom program error: 0x10"), landed(10), landed(100)].each do |error|
      refute Entries::PaymentCopy.ticket_exists?(error), error.message
      assert Entries::PaymentCopy.chain_refusal?(error), error.message
    end
  end

  test "a resend of the same bytes proves nothing either way, and a timeout is not a refusal" do
    refute Entries::PaymentCopy.chain_refusal?(rpc("Transaction simulation failed: This transaction has already been processed"))
    refute Entries::PaymentCopy.chain_refusal?(rpc("Transaction confirmation timeout"))
  end

  test "a program error reads the same in hex and in decimal" do
    { 6004 => :contest_full, 6003 => :contest_locked, 6034 => :contest_locked, 6002 => :insufficient_funds,
      6021 => :program_refused }.each do |number, expected|
      assert_equal expected, code(rpc("#{SIM}custom program error: 0x#{number.to_s(16)}")), "hex #{number}"
      assert_equal expected, code(landed(number)), "decimal #{number}"
      assert_equal number, Entries::PaymentCopy.error_number(landed(number))
    end
  end

  test "custom error 1 is the player's USDC or the house's SOL, and the sentence never guesses" do
    [rpc("#{SIM}custom program error: 0x1"), landed(1)].each do |error|
      assert_equal :funds_or_fee, code(error), "unknown context names both"
      assert_equal :funds_or_fee, code(error, funding: "usdc", funds_confirmed: false)
      assert_equal :network_fee, code(error, funding: "usdc", funds_confirmed: true)
      assert_equal :network_fee, code(error, funding: "token")
    end
    assert_equal :network_fee, code(rpc("#{SIM}Transaction results in an account (0) with insufficient funds for rent"))
    assert_match(/enough USDC.*on our side/m, Entries::PaymentCopy.message(:funds_or_fee))
  end

  test "an on-chain failure has its own sentence: it reached Solana, so 'never reached' would be untrue" do
    assert_match(/reached Solana and was turned down there.*not charged/, Entries::PaymentCopy.message(:failed_onchain))
    assert_match(/never reached Solana/, Entries::PaymentCopy.message(:expired))
    refute_equal Entries::PaymentCopy.message(:expired), Entries::PaymentCopy.message(:failed_onchain)
  end

  test "every sentence is a plain one, and an unknown code falls back to one" do
    Entries::PaymentCopy::COPY.each do |key, (sentence, _retry)|
      assert_match(/\A[A-Z].+[.!]\z/m, sentence, key.to_s)
      refute_match(/0x|RpcError|simulation|Instruction/i, sentence, key.to_s)
    end
    assert_equal Entries::PaymentCopy.message(:failed), Entries::PaymentCopy.message(:something_new)
  end
end
