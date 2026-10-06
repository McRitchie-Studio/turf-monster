# The error_handler behind production's Rails.cache (config/environments/production.rb).
#
# Production's cache is a redis_cache_store on the Sidekiq Redis (REDIS_URL), and
# its error_handler swallows every connection error so a Redis blip cannot 500 a
# request. Swallowed is not silent: a Redis outage turns off every rack-attack
# throttle (config/initializers/rack_attack.rb, "Cache outage") and stops Sidekiq,
# so it has to page someone. A log line alone does not: Sentry keeps log lines only
# as breadcrumbs on some later event.
#
# So every swallowed error is logged, and the first one in each WINDOW is also
# reported through Rails.error under SOURCE, which SentryForwarder sends to Sentry.
# The window is per process (each Puma worker and Sidekiq process keeps its own),
# so an outage raises a handful of Sentry events a minute, not one per cache call.
# Each report carries how many errors the window before it suppressed.
#
# Nothing here may raise: the handler runs inside a cache read on a live request.
class CacheErrorReporter
  SOURCE = "cache_outage.turf_monster".freeze
  WINDOW = 60 # seconds

  # The process's one reporter, built with the class (see the foot of this file)
  # so two threads cannot race to make two and report twice in one window.
  def self.default
    @default
  end

  def self.call(method:, returning:, exception:)
    default.call(method: method, returning: returning, exception: exception)
  end

  # Called from config/initializers/sentry.rb when Sentry is configured. Adds the
  # forwarder unless sentry-rails already subscribes to every report itself.
  def self.subscribe_sentry!(error_reporter = Rails.error)
    return if Sentry.configuration&.rails&.register_error_subscriber

    error_reporter.subscribe(SentryForwarder.new)
  end

  attr_reader :window

  def initialize(window: WINDOW, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @window = window
    @clock = clock
    @mutex = Mutex.new
    reset!
  end

  def call(method:, returning:, exception:)
    log(method, exception)
    suppressed = claim_report
    report(method, exception, suppressed) unless suppressed.nil?
    nil
  end

  def reset!
    @mutex.synchronize do
      @reported_at = nil
      @suppressed = 0
    end
  end

  private

  # The count of errors suppressed since the last report when this error is due
  # a report, nil when it is not.
  def claim_report
    @mutex.synchronize do
      now = @clock.call
      if @reported_at.nil? || now - @reported_at >= window
        suppressed = @suppressed
        @reported_at = now
        @suppressed = 0
        suppressed
      else
        @suppressed += 1
        nil
      end
    end
  rescue StandardError
    nil
  end

  def log(method, exception)
    Rails.logger.error("[cache] #{method} failed: #{exception.class}: #{exception.message}")
  rescue StandardError
    nil
  end

  def report(method, exception, suppressed)
    Rails.error.report(
      exception,
      handled: true,
      severity: :error,
      source: SOURCE,
      context: {
        cache_method: method.to_s,
        suppressed_since_last_report: suppressed,
        window_seconds: window,
        pid: Process.pid,
        tags: { cache_outage: true }
      }
    )
  rescue StandardError => e
    begin
      Rails.logger.error("[cache] outage report failed: #{e.class}: #{e.message}")
    rescue StandardError
      nil
    end
  end

  # A Rails.error subscriber that sends only this reporter's reports to Sentry.
  # sentry-rails leaves its own all-reports subscriber off by default
  # (config.rails.register_error_subscriber = false), and turning that on would
  # send every report Rails makes, so this forwards one source.
  class SentryForwarder
    def report(error, handled:, severity:, context:, source: nil)
      return unless source == SOURCE

      sentry_subscriber.report(error, handled: handled, severity: severity, context: context, source: source)
    end

    private

    def sentry_subscriber
      @sentry_subscriber ||= begin
        require "sentry/rails/error_subscriber"
        Sentry::Rails::ErrorSubscriber.new
      end
    end
  end

  @default = new
end
