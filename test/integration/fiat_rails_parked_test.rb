require "test_helper"
require "minitest/mock"

# [integration] The fiat rails are parked behind ENABLE_FIAT_RAILS
# (AppFlags.fiat_rails?, docs/FIAT_RAILS.md). With the flag off, every parked
# route answers 404 to a logged-out visitor, a signed-in player and a provider
# webhook alike; the views offer no fiat rail even when every per-provider
# switch is on; and the parked jobs skip. Each test carries its control: the
# same request or render with the flag on reaches the rail.
class FiatRailsParkedTest < ActionDispatch::IntegrationTest
  setup do
    @provider_was = Rails.application.config.x.payment_provider
    @stripe_was   = Rails.application.config.x.stripe_enabled
    @paypal_was   = Rails.application.config.x.paypal_enabled
  end

  teardown do
    Rails.application.config.x.payment_provider = @provider_was
    Rails.application.config.x.stripe_enabled   = @stripe_was
    Rails.application.config.x.paypal_enabled   = @paypal_was
  end

  # Every drawn route whose controller action FiatRailsParked lists, as
  # [verb, path] pairs. Read from the router, so a parked route that is drawn
  # under a new path is still swept.
  def parked_routes
    Rails.application.routes.routes.filter_map do |route|
      controller = route.defaults[:controller]
      action = route.defaults[:action]
      next unless controller && action
      next unless FiatRailsParked.parked_action?(controller, action)

      verb = route.verb.to_s.split("|").first.presence&.downcase || "get"
      [verb, route.path.spec.to_s.sub("(.:format)", "")]
    end.uniq
  end

  def with_env(pairs)
    originals = pairs.keys.index_with { |key| ENV[key] }
    pairs.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    originals.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def with_fiat_rails(on, &block)
    with_env({ "ENABLE_FIAT_RAILS" => (on ? "true" : nil) }, &block)
  end

  # Every per-provider switch ON, so only the master flag can hide a rail.
  def with_every_provider_on(&block)
    Rails.application.config.x.payment_provider = "paypal"
    Rails.application.config.x.paypal_enabled = true
    Rails.application.config.x.stripe_enabled = true
    with_env({ "ENABLE_COINFLOW" => "true", "ENABLE_AEROPAY" => "true" }, &block)
  end

  def request_route(verb, path)
    public_send(verb, path, headers: { "CONTENT_TYPE" => "application/json" }, params: "{}")
  end

  test "integration the sweep finds every parked controller in the router" do
    swept = parked_routes.map(&:last)

    %w[/tokens/stripe_checkout /tokens/paypal_order /tokens/paypal_capture /tokens/coinflow_order
       /tokens/aeropay_order /tokens/processing /tokens/status /wallet/stripe_deposit
       /webhooks/stripe /webhooks/paypal /webhooks/coinflow /webhooks/aeropay].each do |path|
      assert_includes swept, path, "#{path} is not swept; the parked list and the routes disagree"
    end
  end

  test "integration with the flag off every parked route answers 404 to a logged-out request" do
    with_fiat_rails(false) do
      parked_routes.each do |verb, path|
        request_route(verb, path)
        assert_equal 404, response.status, "#{verb.upcase} #{path} answered #{response.status} while parked"
      end
    end
  end

  test "integration control: with the flag on no parked route answers 404 to a logged-out request" do
    with_fiat_rails(true) do
      parked_routes.each do |verb, path|
        request_route(verb, path)
        refute_equal 404, response.status, "#{verb.upcase} #{path} 404s with the flag on; the 404 sweep above proves nothing for it"
      end
    end
  end

  test "integration with the flag off a signed-in player gets 404 from the purchase endpoints" do
    log_in_as users(:jordan)

    with_fiat_rails(false) do
      post tokens_stripe_checkout_path, params: { pack: "single" }
      assert_response :not_found
      post tokens_coinflow_order_path, params: { pack: "single" }, as: :json
      assert_response :not_found
      get tokens_status_path, params: { session_id: "cs_test_parked" }, as: :json
      assert_response :not_found
    end

    # Control: the same player reaches the status poll with the flag on.
    with_fiat_rails(true) do
      get tokens_status_path, params: { session_id: "cs_test_parked" }, as: :json
      assert_response :success
    end
  end

  test "integration with the flag off the buy page offers no fiat rail even with every provider switched on" do
    log_in_as users(:jordan)

    with_every_provider_on do
      with_fiat_rails(false) do
        get tokens_buy_path
        assert_response :success
        assert_no_match(/data-coinflow-buy|data-aeropay-buy|paypal\.com\/sdk|tokens\/stripe_checkout/, response.body)
        assert_match(/data-fiat-rails-parked/, response.body)
      end

      # Control: the flag on brings the rails back.
      with_fiat_rails(true) do
        get tokens_buy_path
        assert_match(/data-coinflow-buy/, response.body)
        assert_match(/data-aeropay-buy/, response.body)
        assert_no_match(/data-fiat-rails-parked/, response.body)
      end
    end
  end

  test "integration with the flag off the wallet-deposit modal carries no card form" do
    log_in_as users(:jordan)

    with_fiat_rails(false) do
      get root_path
      assert_response :success
      assert_no_match(%r{/wallet/stripe_deposit}, response.body)
    end

    # Control: the card form renders in the layout with the flag on.
    with_fiat_rails(true) do
      get root_path
      assert_match(%r{/wallet/stripe_deposit}, response.body)
    end
  end

  test "integration with the flag off each parked job skips perform and says so" do
    FiatRailsParked::JOBS.each do |name|
      job = name.constantize.new
      ran = false

      logs = capture_logs do
        with_fiat_rails(false) { job.stub(:perform, ->(*) { ran = true }) { job.perform_now } }
      end
      refute ran, "#{name} ran while parked"
      assert_match(/\[fiat-parked\] skipped #{name}/, logs)

      # Control: the same job runs with the flag on.
      with_fiat_rails(true) { job.stub(:perform, ->(*) { ran = true }) { job.perform_now } }
      assert ran, "#{name} did not run with the flag on; the skip above proves nothing"
    end
  end

  test "integration an unparked job runs with the flag off" do
    job = OutboundRequestSweeperJob.new
    ran = false
    with_fiat_rails(false) { job.stub(:perform, ->(*) { ran = true }) { job.perform_now } }
    assert ran, "the fiat gate skipped a job that is not parked"
  end

  private

  def capture_logs
    buffer = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(buffer)
    yield
    buffer.string
  ensure
    Rails.logger = original
  end
end
