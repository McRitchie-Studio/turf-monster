require "test_helper"
require "minitest/mock"

# Solana::Deadline over the gem's real Solana::Client. The wire answers 429
# (test/support/throttled_rpc.rb) and every sleep moves a fake clock.
class SolanaDeadlineTest < ActiveSupport::TestCase
  Exceeded = Solana::Deadline::Exceeded

  setup { @now = [1_000.0] }

  def throttled(**opts)
    rpc = ThrottledRpc.client(**opts)
    slept = rpc.slept
    now = @now
    rpc.define_singleton_method(:sleep) do |seconds|
      slept << seconds
      now[0] += seconds
    end
    rpc
  end

  def fake_clock(&block)
    Solana::Deadline.stub(:clock, -> { @now[0] }, &block)
  end

  test "sum_of_waits_bounded: the waits of every call under one deadline sum to no more than it" do
    rpc = throttled(retry_after: 3)

    fake_clock do
      Solana::Deadline.within(7) do
        assert_raises(Exceeded) { rpc.get_account_info("Wallet") }
        assert_raises(Exceeded) { rpc.get_account_info("Wallet") }
      end
    end

    assert_equal 2, rpc.slept.size, "two 3s waits fit 7s, a third does not"
    assert_operator rpc.slept.sum, :<=, 7
  end

  test "CONTROL: with no deadline the same two calls wait past 7 seconds and raise the 429" do
    rpc = throttled(retry_after: 3)

    2.times { assert_raises(Solana::Client::HttpError) { rpc.get_account_info("Wallet") } }

    assert_operator rpc.slept.sum, :>, 7
  end

  test "a call that starts with no time left raises before the wire" do
    rpc = throttled

    fake_clock { Solana::Deadline.within(0) { assert_raises(Exceeded) { rpc.get_account_info("Wallet") } } }

    assert_equal 0, rpc.posts
  end

  test "a call its own smaller budget stops raises its own error, not Exceeded" do
    rpc = throttled(retry_after: 3)

    fake_clock do
      Solana::Deadline.within(25) do
        Solana::Client.with_wait_budget(2) do
          assert_raises(Solana::Client::HttpError) { rpc.get_account_info("Wallet") }
        end
      end
    end

    assert_empty rpc.slept
  end

  test "a long-budget call keeps its own budget when the deadline has passed" do
    rpc = throttled(retry_after: 3)

    fake_clock do
      Solana::Deadline.within(1) do
        @now[0] += 5
        Solana::Deadline.long_budget(:managed_entry_spend) do
          error = assert_raises(Solana::Client::HttpError) { rpc.get_account_info("Wallet") }
          assert_equal 15.0, error.call_stats.budget
        end
      end
    end

    assert_equal 3, rpc.slept.size, "all three retries ran"
  end

  test "CONTROL: the same read outside the long-budget block is refused" do
    rpc = throttled(retry_after: 3)

    fake_clock do
      Solana::Deadline.within(1) do
        @now[0] += 5
        assert_raises(Exceeded) { rpc.get_account_info("Wallet") }
      end
    end

    assert_empty rpc.slept
  end

  test "long_budget takes only a name on the list" do
    assert_raises(KeyError) { Solana::Deadline.long_budget(:anything) { flunk } }
    Solana::Deadline::LONG_BUDGET_ACTIONS.each_value { |name| assert Solana::Deadline::LONG_BUDGET.key?(name), name.to_s }
  end

  test "a send goes out with no time left, and the calls after it are not refused" do
    rpc = throttled(succeed_after: 0, result: { "value" => nil })

    fake_clock do
      Solana::Deadline.within(0) do
        rpc.send_transaction("WIRE")
        rpc.confirm_transaction("SIG")
        assert_nil Solana::Deadline.remaining
      end
    end

    assert_equal 2, rpc.posts
  end

  test "CONTROL: with no send before it, the confirm read is refused" do
    rpc = throttled(succeed_after: 0)

    fake_clock { Solana::Deadline.within(0) { assert_raises(Exceeded) { rpc.confirm_transaction("SIG") } } }
  end

  test "a send inside a nested deadline releases the outer one too" do
    rpc = throttled(succeed_after: 0)

    fake_clock do
      Solana::Deadline.within(25) do
        Solana::Deadline.within(120) { rpc.send_transaction("WIRE") }
        assert_nil Solana::Deadline.remaining
      end
      assert_nil Current.rpc_deadline
    end
  end

  test "a nested deadline keeps the sooner one" do
    fake_clock do
      Solana::Deadline.within(25) do
        Solana::Deadline.within(120) { assert_equal 25, Solana::Deadline.remaining }
        Solana::Deadline.within(3) { assert_equal 3, Solana::Deadline.remaining }
        assert_equal 25, Solana::Deadline.remaining
      end
    end
  end

  test "a thread takes the deadline as an argument" do
    fake_clock do
      Solana::Deadline.within(25) do
        deadline = Solana::Deadline.current
        assert_equal 25, Thread.new { Solana::Deadline.at(deadline) { Solana::Deadline.remaining } }.value
        assert_nil Thread.new { Solana::Deadline.remaining }.value, "CONTROL: a bare thread has no deadline"
      end
    end
  end

  test "a long-budget block hands a thread no deadline" do
    Solana::Deadline.within(25) do
      Solana::Deadline.long_budget(:entry_confirm) { assert_nil Solana::Deadline.current }
      assert_not_nil Solana::Deadline.current
    end
  end

  test "the deadline wraps the logger, so a refused call writes no outbound row" do
    chain = Solana::Client.ancestors
    assert_operator chain.index(Solana::Deadline::ClientCall), :<, chain.index(Solana::ClientLogger)

    rpc = throttled
    assert_no_difference "OutboundRequest.count" do
      Solana::Deadline.within(0) { assert_raises(Exceeded) { rpc.get_account_info("Wallet") } }
    end
  end
end
