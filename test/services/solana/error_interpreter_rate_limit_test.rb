require "test_helper"

# A rate limit the request's wait budget could not outlast reads as "busy",
# not as the raw "HTTP 429 from RPC:" string (turf-wires-rpc-wait-budgets).
class Solana::ErrorInterpreterRateLimitTest < ActiveSupport::TestCase
  BUSY = "The Solana network is busy right now — please try again in a moment.".freeze

  test "the gem's HTTP 429 reads as busy, as a toast" do
    error = Solana::Client::HttpError.new("HTTP 429 from RPC: Too many requests", code: 429)
    result = Solana::ErrorInterpreter.interpret(error)

    assert_equal BUSY, result[:message]
    assert result[:toast]
    assert_nil result[:blocker]
  end

  test "a JSON-RPC rate limit (code 429) reads as busy" do
    error = Solana::Client::RpcError.new("Rate limit exceeded", code: 429)
    assert_equal BUSY, Solana::ErrorInterpreter.interpret(error)[:message]
  end

  test "CONTROL: a broadcast failure that wraps a 429 is NOT told to try again" do
    # A send that failed may have landed; "try again" would invite a second pay.
    error = Solana::Cosign::BroadcastFailed.new(
      "send failed — reconcile before rebuilding: HTTP 429 from RPC: Too many requests"
    )
    refute_equal BUSY, Solana::ErrorInterpreter.interpret(error)[:message]
  end

  test "CONTROL: another HTTP status is not a rate limit" do
    error = Solana::Client::HttpError.new("HTTP 503 from RPC: upstream unavailable", code: 503)
    refute_equal BUSY, Solana::ErrorInterpreter.interpret(error)[:message]
  end
end
