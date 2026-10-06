require "test_helper"
require "sentry/rails/error_subscriber"

# [unit] CacheErrorReporter, the error_handler behind production's Rails.cache
# (config/environments/production.rb): it logs every swallowed Redis error and
# reports the first in each window, per process, through Rails.error, which
# SentryForwarder sends to Sentry. Through real requests on a failing store:
# test/integration/cache_outage_reporting_test.rb.
class CacheErrorReporterTest < ActiveSupport::TestCase
  # A Rails.error subscriber that keeps what it was given.
  class Collector
    attr_reader :reports

    def initialize
      @reports = []
    end

    def report(error, handled:, severity:, context:, source: nil)
      @reports << { error: error, handled: handled, severity: severity, context: context, source: source }
    end
  end

  class RaisingSubscriber
    def report(*, **)
      raise "the reporter is down too"
    end
  end

  setup do
    @now = 1_000.0
    @reporter = CacheErrorReporter.new(window: 60, clock: -> { @now })
    @collector = Collector.new
    Rails.error.subscribe(@collector)
    @log = StringIO.new
    @prior_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(@log)
  end

  teardown do
    Rails.error.unsubscribe(@collector)
    Rails.logger = @prior_logger
  end

  def outage_error
    Redis::CannotConnectError.new("Connection refused - connect(2) for 127.0.0.1:6379")
  end

  def fail_cache(times, method: :increment, reporter: @reporter)
    times.times { reporter.call(method: method, returning: nil, exception: outage_error) }
  end

  def ours
    @collector.reports.select { |r| r[:source] == CacheErrorReporter::SOURCE }
  end

  def log_lines
    @log.string.lines.grep(/\[cache\] increment failed: Redis::CannotConnectError/)
  end

  test "a flood of cache errors in one window reports once and logs every one" do
    fail_cache(50)

    assert_equal 1, ours.size
    assert_equal 50, log_lines.size
    report = ours.first
    assert_instance_of Redis::CannotConnectError, report[:error]
    assert report[:handled]
    assert_equal :error, report[:severity]
    assert_equal "increment", report[:context][:cache_method]
    assert_equal 0, report[:context][:suppressed_since_last_report]
    assert_equal 60, report[:context][:window_seconds]
    assert_equal({ cache_outage: true }, report[:context][:tags])
  end

  test "the next window reports again, carrying how many the last one suppressed" do
    fail_cache(10)
    @now += 59.9
    fail_cache(5)
    assert_equal 1, ours.size

    @now += 0.1
    fail_cache(3, method: :read)

    assert_equal 2, ours.size
    assert_equal 14, ours.last[:context][:suppressed_since_last_report]
    assert_equal "read", ours.last[:context][:cache_method]
    assert_equal 18, @log.string.lines.grep(/\[cache\] (increment|read) failed/).size
  end

  test "threads failing at once in one window raise one report" do
    Array.new(8) { Thread.new { fail_cache(25) } }.each(&:join)

    assert_equal 1, ours.size
    assert_equal 200, log_lines.size
  end

  test "the class-level handler production calls is one shared reporter" do
    assert_same CacheErrorReporter.default, CacheErrorReporter.default
    CacheErrorReporter.default.reset!
    3.times { CacheErrorReporter.call(method: :increment, returning: nil, exception: outage_error) }
    assert_equal 1, ours.size
  ensure
    CacheErrorReporter.default.reset!
  end

  test "a subscriber that raises cannot break the cache call" do
    raising = RaisingSubscriber.new
    Rails.error.subscribe(raising)

    assert_nil @reporter.call(method: :increment, returning: nil, exception: outage_error)
    assert_equal 1, log_lines.size
  ensure
    Rails.error.unsubscribe(raising)
  end

  test "Rails.error.report raising cannot break the cache call, and is logged" do
    Rails.error.stub(:report, ->(*, **) { raise ArgumentError, "report blew up" }) do
      assert_nil @reporter.call(method: :increment, returning: nil, exception: outage_error)
    end
    assert_equal 1, log_lines.size
    assert_match(/\[cache\] outage report failed: ArgumentError: report blew up/, @log.string)
  end

  test "a logger that raises cannot break the cache call or stop the report" do
    broken = Object.new
    def broken.error(*) = raise(IOError, "log pipe closed")
    Rails.logger = broken

    assert_nil @reporter.call(method: :increment, returning: nil, exception: outage_error)
    assert_equal 1, ours.size
  end

  test "SentryForwarder sends only the outage source to Sentry" do
    captured = []
    capture = ->(error, **options) { captured << [error, options] }
    forwarder = CacheErrorReporter::SentryForwarder.new
    error = outage_error

    Sentry::Rails.stub(:capture_exception, capture) do
      forwarder.report(RuntimeError.new("other"), handled: true, severity: :warning, context: {}, source: "application")
      forwarder.report(RuntimeError.new("no source"), handled: true, severity: :warning, context: {})
      forwarder.report(error, handled: true, severity: :error,
        context: { cache_method: "increment", tags: { cache_outage: true } }, source: CacheErrorReporter::SOURCE)
    end

    assert_equal 1, captured.size
    assert_same error, captured.first[0]
    assert_equal :error, captured.first[1][:level]
    assert_equal true, captured.first[1][:tags][:cache_outage]
    assert_equal CacheErrorReporter::SOURCE, captured.first[1][:tags][:source]
  end

  test "the outage source is not one sentry-rails skips as cache noise" do
    refute_match Sentry::Rails::ErrorSubscriber::SKIP_SOURCES, CacheErrorReporter::SOURCE
  end

  test "subscribe_sentry! adds the forwarder, unless sentry-rails already subscribes to everything" do
    reporter = ActiveSupport::ErrorReporter.new
    rails_config = Struct.new(:register_error_subscriber)
    config = Struct.new(:rails)

    Sentry.stub(:configuration, config.new(rails_config.new(false))) do
      CacheErrorReporter.subscribe_sentry!(reporter)
    end
    subscribers = reporter.instance_variable_get(:@subscribers)
    assert_equal 1, subscribers.count { |s| s.is_a?(CacheErrorReporter::SentryForwarder) }

    other = ActiveSupport::ErrorReporter.new
    Sentry.stub(:configuration, config.new(rails_config.new(true))) do
      CacheErrorReporter.subscribe_sentry!(other)
    end
    assert_empty other.instance_variable_get(:@subscribers)
  end

  test "production's cache error_handler and the Sentry initializer call the reporter" do
    production = Rails.root.join("config/environments/production.rb").read
    handler = production[/error_handler: ->\(method:, returning:, exception:\) \{\n(.*?)\n\s*\}/m, 1]
    assert_equal "CacheErrorReporter.call(method: method, returning: returning, exception: exception)", handler&.strip

    sentry = Rails.root.join("config/initializers/sentry.rb").read
    inside_dsn_guard = sentry[/^if ENV\["SENTRY_DSN"\]\.present\?\n(.*)^end$/m, 1]
    assert_includes inside_dsn_guard, "Rails.application.config.after_initialize { CacheErrorReporter.subscribe_sentry! }"
  end
end
