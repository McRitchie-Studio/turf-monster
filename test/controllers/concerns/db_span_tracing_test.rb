require "test_helper"

# Unit coverage for the DbSpanTracing concern (fix-turf-latency-tail).
#
# Exercised in isolation via a bare harness that includes the module and
# supplies the controller surface it touches (request/controller_name/
# action_name). Asserts the span is RECORDED and EMITTED, that it is
# transparent to the wrapped action, and — the load-bearing property — that a
# failure anywhere in the instrumentation is a no-op that can never raise into
# (or swallow the result of) the request.
class DbSpanTracingTest < ActiveSupport::TestCase
  # Minimal stand-in for a controller that opts into the concern.
  class Harness
    include DbSpanTracing
    attr_accessor :action_name, :controller_name

    def initialize
      @action_name = "world_cup"
      @controller_name = "contests"
    end

    def request
      @request ||= Struct.new(:path).new("/")
    end

    # Public shim so tests can drive the private around_action entry point.
    def run(&block)
      trace_db_span(&block)
    end
  end

  setup { @harness = Harness.new }

  def capturing_logs
    captured = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(captured)
    yield
    captured.string
  ensure
    Rails.logger = original
  end

  test "is transparent — returns the wrapped action's value" do
    assert_equal :redirected, @harness.run { :redirected }
  end

  test "emits a structured [db-span] line with connect + execute + query count" do
    log = capturing_logs do
      @harness.run { Contest.count } # one real sql.active_record event
    end

    assert_match(%r{\[db-span\] path=/}, log)
    assert_match(/connect=[\d.]+ms/, log)
    assert_match(/execute=[\d.]+ms/, log)
    assert_match(/queries=\d+/, log)
    assert_match(/controller=contests#world_cup/, log)
  end

  test "records connect and execute spans separately" do
    captured = nil
    @harness.define_singleton_method(:db_span_emit) { |**kwargs| captured = kwargs }

    @harness.run { Contest.count }

    assert_instance_of Float, captured[:connect_ms], "connect time should be measured on a live pool"
    assert captured[:execute_ms] >= 0.0
    assert captured[:query_count] >= 1, "a real query should be counted"
    assert captured[:total_ms] >= 0.0
  end

  test "no-op-safe when the connect probe fails — action still runs, no raise" do
    result = nil
    log = capturing_logs do
      ActiveRecord::Base.stub(:connection_pool, -> { raise "boom" }) do
        result = @harness.run { :ok }
      end
    end

    assert_equal :ok, result
    assert_match(%r{connect=n/a}, log)
    assert_match(/connect probe failed/, log)
  end

  test "no-op-safe when emit itself raises — action value preserved, no raise" do
    @harness.define_singleton_method(:db_span_emit) { |**| raise "kaboom" }

    assert_nothing_raised do
      assert_equal :still_ok, @harness.run { :still_ok }
    end
  end

  test "adds no DB work when disabled via DB_SPAN_TRACE=0" do
    ran = false
    ENV["DB_SPAN_TRACE"] = "0"
    # If disabled, the connection probe must never fire — stub it to blow up to
    # prove the disabled path is a pure pass-through.
    result = ActiveRecord::Base.stub(:connection_pool, -> { raise "should not connect" }) do
      @harness.run { ran = true; :direct }
    end

    assert ran
    assert_equal :direct, result
  ensure
    ENV.delete("DB_SPAN_TRACE")
  end
end
