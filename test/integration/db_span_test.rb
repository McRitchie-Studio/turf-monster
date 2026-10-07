require "test_helper"

# Integration coverage for the DB-span instrumentation (fix-turf-latency-tail):
# the around_action is wired onto the two hot paths — "/" (the contests lobby)
# and the contest show page — and the span reaches the log sink on a real
# request, without changing the response.
class DbSpanTest < ActionDispatch::IntegrationTest
  setup { @contest = contests(:one) }

  def capturing_logs
    captured = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(captured)
    yield
    captured.string
  ensure
    Rails.logger = original
  end

  test "the lobby emits a connect/execute [db-span] line without changing the response" do
    log = capturing_logs { get contests_path }

    assert_response :success
    assert_match(%r{\[db-span\] path=/contests}, log)
    assert_match(/connect=([\d.]+ms|n\/a)/, log)
    assert_match(/execute=[\d.]+ms/, log)
    assert_match(/controller=contests#index/, log)
  end

  test "contest show emits a [db-span] line and still renders" do
    log = capturing_logs { get contest_path(@contest) }

    assert_response :success
    assert_match(/\[db-span\].*controller=contests#show/, log)
  end

  test "DB_SPAN_TRACE=0 disables the span but the page still serves" do
    ENV["DB_SPAN_TRACE"] = "0"
    log = capturing_logs { get contests_path }

    assert_response :success
    refute_match(/\[db-span\]/, log)
  ensure
    ENV.delete("DB_SPAN_TRACE")
  end
end
