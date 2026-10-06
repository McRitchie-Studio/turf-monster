require "test_helper"

# [integration] Real requests through Rack::Attack while Redis is down, on a store
# whose error_handler is production's (CacheErrorReporter.call): a sign-in flood
# raises one Rails.error report for the window and a log line per swallowed
# error, and a reporter that fails cannot fail the request. The unit proof is
# test/services/cache_error_reporter_test.rb.
class CacheOutageReportingTest < ActionDispatch::IntegrationTest
  class Collector
    attr_reader :reports

    def initialize
      @reports = []
    end

    def report(error, handled:, severity:, context:, source: nil)
      @reports << [error, source] if source == CacheErrorReporter::SOURCE
    end
  end

  class RaisingSubscriber
    def report(*, **)
      raise "Sentry is unreachable as well"
    end
  end

  setup do
    CacheErrorReporter.default.reset!
    @collector = Collector.new
    Rails.error.subscribe(@collector)
    @log = StringIO.new
    @prior_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(@log)
  end

  teardown do
    Rails.error.unsubscribe(@collector)
    Rails.logger = @prior_logger
    CacheErrorReporter.default.reset!
  end

  def handler
    CacheErrorReporter.method(:call)
  end

  def sign_ins(times)
    Array.new(times) do
      post "/login", params: { email: "fan@example.com" }
      response.status
    end
  end

  test "a sign-in flood during an outage raises one report and logs every swallowed error" do
    RedisCacheOutage.with_rack_attack(handler: handler) do |swallowed|
      statuses = sign_ins(12)

      assert statuses.all? { |status| status < 500 }, statuses.inspect
      refute_empty swallowed, "the store must actually have failed"
      assert_equal 1, @collector.reports.size
      assert_kind_of Redis::BaseConnectionError, @collector.reports.first.first
      assert_equal swallowed.size, @log.string.lines.grep(/\[cache\] \w+ failed: Redis::/).size
    end
  end

  test "a reporter that raises cannot fail the request" do
    raising = RaisingSubscriber.new
    Rails.error.subscribe(raising)

    RedisCacheOutage.with_rack_attack(handler: handler) do |swallowed|
      statuses = sign_ins(3)

      assert statuses.all? { |status| status < 500 }, statuses.inspect
      refute_empty swallowed
      assert_equal 1, @collector.reports.size
    end
  ensure
    Rails.error.unsubscribe(raising)
  end
end
