require "test_helper"

# Solana::ClientLogger records what the gem's #call DID — retries, seconds
# waited, the budget, and whether the budget stopped it — on the
# outbound_requests row (solana-studio >= 0.12.3 CallStats). Driven through a
# REAL Solana::Client with only its wire and its clock replaced
# (test/support/throttled_rpc.rb), so the numbers are the gem's own.
class Solana::ClientLoggerWaitStatsTest < ActiveSupport::TestCase
  test "ClientLogger is prepended over the real client, so these rows come from it" do
    assert_includes Solana::Client.ancestors, Solana::ClientLogger
  end

  test "a read that recovers after retries is logged, with its retries and time waited" do
    client = ThrottledRpc.client(retry_after: 1, succeed_after: 2)

    assert_difference -> { OutboundRequest.count }, 1 do
      client.get_account_info("SomeAccount")
    end

    body = OutboundRequest.last.request_body
    assert_equal "getAccountInfo", OutboundRequest.last.method
    assert_equal 200, OutboundRequest.last.status_code
    assert_equal 2, body["retries"]
    assert_equal (client.slept.sum * 1000).round, body["waited_ms"]
    assert_operator body["waited_ms"], :>, 0
    assert_equal false, body["budget_stopped"]
    assert_equal 15_000, body["budget_ms"], "outside a request the gem's 15s default applies"
  end

  test "CONTROL: a read that needed no retry still writes no row" do
    client = ThrottledRpc.client(succeed_after: 0)

    assert_no_difference -> { OutboundRequest.count } do
      client.get_account_info("SomeAccount")
    end
    assert_empty client.slept
  end

  test "a sustained 429 stopped by the budget records budget_stopped and the error" do
    client = ThrottledRpc.client(retry_after: 3)

    Solana::Client.with_wait_budget(5) do
      assert_raises(Solana::Client::HttpError) { client.get_account_info("SomeAccount") }
    end

    row = OutboundRequest.last
    assert_equal "Solana::Client::HttpError", row.error_class
    assert_equal 1, row.request_body["retries"], "one 3s wait fits a 5s budget, a second does not"
    assert_equal true, row.request_body["budget_stopped"]
    assert_equal 5_000, row.request_body["budget_ms"]
    assert_operator row.request_body["waited_ms"], :<=, 5_000
  end

  test "a write with no retries carries zeroed stats" do
    client = ThrottledRpc.client(succeed_after: 0, result: "SIG")

    client.send_transaction("BASE64WIRE")

    body = OutboundRequest.last.request_body
    assert_equal "sendTransaction", OutboundRequest.last.method
    assert_equal 0, body["retries"]
    assert_equal 0, body["waited_ms"]
    assert_equal false, body["budget_stopped"]
  end

  test "stats are read per thread, so a shared client never logs another thread's numbers" do
    client = ThrottledRpc.client(succeed_after: 0, result: "SIG")
    client.send_transaction("BASE64WIRE")
    mine = client.last_call_stats

    other = Thread.new { client.last_call_stats }.value

    assert_equal "sendTransaction", mine.method
    assert_nil other, "a thread that made no call sees no stats, even on the same client"
  end
end
