# DbSpanTracing — attribute request DB wall time to CONNECT vs EXECUTE.
#
# Why: mainnet "/" (ContestsController#world_cup) is a 302 redirect that runs a
# handful of trivial queries, yet the Heroku router sees a p99 of ~10s while p50
# is ~60ms. The Rails log for the slow ones reads
#   "Completed 302 Found in 4287ms (ActiveRecord: 4241.4ms (4 queries, 1 cached))"
# so ~99% of the wall time is *inside ActiveRecord* across four queries that
# normally run in 2-9ms. It is not an N+1 and not app code. The leading (but
# UNPROVEN) hypothesis is cold/reaped Postgres connection re-establishment after
# idle gaps — a cost that hides inside the first query's execution time.
#
# This span makes that split observable so a FUTURE pass can prove or kill the
# hypothesis. Before the action runs it eagerly checks out and verifies the
# pooled connection, timing THAT reconnect separately (connect_ms). It then
# sums the sql.active_record durations for the action itself (execute_ms). If
# the hypothesis holds, a cold request lands ~4000ms in connect_ms and only a
# few ms in execute_ms.
#
# It is OBSERVABILITY ONLY:
#   * it never changes the response (verify! reconnects a dead connection, which
#     the first query would have done anyway — behavior is identical),
#   * every step is guarded so a failure in the instrumentation can never raise
#     into the request, and
#   * the per-request overhead is a single connection liveness ping (sub-ms on a
#     warm pool), so it adds no meaningful latency.
#
# The controller opts in with an around_action (see ContestsController); the
# concern itself declares no controller DSL so it stays unit-testable in
# isolation. Disable in an environment with DB_SPAN_TRACE=0.
module DbSpanTracing
  extend ActiveSupport::Concern

  private

  # around_action entry point. Runs the wrapped action inside a DB span and
  # emits the connect-vs-execute breakdown afterward. Returns the block's value
  # so it is transparent to the framework.
  def trace_db_span
    return yield unless db_span_tracing_enabled?

    connect_ms = db_span_measure_connect
    execute = { ms: 0.0, count: 0 }
    subscriber = db_span_subscribe(execute)
    started_ms = db_span_monotonic_ms

    begin
      yield
    ensure
      # The whole teardown is guarded: instrumentation must never turn a healthy
      # response into a 500, and must never mask the real error on a failing one.
      begin
        ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
        db_span_emit(
          connect_ms: connect_ms,
          execute_ms: execute[:ms],
          query_count: execute[:count],
          total_ms: db_span_monotonic_ms - started_ms
        )
      rescue => e
        db_span_warn("emit failed: #{e.class}: #{e.message}")
      end
    end
  end

  def db_span_tracing_enabled?
    ENV.fetch("DB_SPAN_TRACE", "1") != "0"
  end

  # Eagerly acquire + verify the request's pooled connection, timing the check
  # (and any re-establishment of a reaped/dead socket) so it is attributed to
  # connect rather than hiding inside the first query. Returns elapsed ms, or
  # nil if the probe itself failed (never raises).
  def db_span_measure_connect
    started = db_span_monotonic_ms
    ActiveRecord::Base.connection_pool.with_connection { |conn| conn.verify! }
    db_span_monotonic_ms - started
  rescue => e
    db_span_warn("connect probe failed: #{e.class}: #{e.message}")
    nil
  end

  # Subscribe to sql.active_record for the life of the action, accumulating real
  # (non-cached) query execution time and count into the passed-in hash.
  def db_span_subscribe(execute)
    ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
      payload = event.payload
      next if payload[:cached]
      # SCHEMA / TRANSACTION control statements are not the queries under study.
      next if %w[SCHEMA TRANSACTION].include?(payload[:name])

      execute[:ms] += event.duration
      execute[:count] += 1
    end
  rescue => e
    db_span_warn("subscribe failed: #{e.class}: #{e.message}")
    nil
  end

  # Emit the span to every sink we have: a structured log line (always — it
  # lands in the Heroku log stream next to the "Completed ... (ActiveRecord: ...)"
  # line) and, when Sentry is live, request-scoped context + a breadcrumb so any
  # captured event carries the split.
  def db_span_emit(connect_ms:, execute_ms:, query_count:, total_ms:)
    connect = connect_ms&.round(1)
    execute = execute_ms.round(1)
    total = total_ms.round(1)
    path = (request.path rescue nil)

    Rails.logger.info(
      "[db-span] path=#{path} connect=#{connect || 'n/a'}ms execute=#{execute}ms " \
      "queries=#{query_count} total=#{total}ms " \
      "controller=#{controller_name}##{action_name}"
    )

    db_span_emit_sentry(
      path: path, connect_ms: connect, execute_ms: execute,
      query_count: query_count, total_ms: total
    )
  end

  def db_span_emit_sentry(context)
    return unless defined?(Sentry) && Sentry.respond_to?(:initialized?) && Sentry.initialized?

    Sentry.set_context("db_span", context)
    Sentry.add_breadcrumb(
      Sentry::Breadcrumb.new(category: "db_span", level: "info", message: "db span", data: context)
    )
  rescue => e
    db_span_warn("sentry emit failed: #{e.class}: #{e.message}")
  end

  def db_span_monotonic_ms
    Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
  end

  def db_span_warn(message)
    Rails.logger.warn("[db-span] #{message}")
  rescue
    # Even the warning path must not raise.
    nil
  end
end
