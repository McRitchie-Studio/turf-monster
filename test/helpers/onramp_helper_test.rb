require "test_helper"

# onramp_rail_visible? gates each rail card in the Add Funds hub
# (modals/_onramp_hub): every rail shows locally (dev/test) so the hub is
# always exercisable, but in production each rail reveals only when its own
# backend flag is live. Flag manipulation mirrors payments_test.rb +
# app_flags_test.rb (config.x.payment_provider / .stripe_enabled /
# .paypal_enabled + ENABLE_CDP_RAMP); production is faked with the same
# Rails.env.stub the webhook controller tests use.
#
# COINBASE IS THE EXCEPTION and is tested apart from the others. Its rail opens
# a MODAL rather than a route, and that modal is registered by the host layout
# behind cdp_ramp_modal_available?. So it must gate on that same predicate in
# EVERY environment: the show-everything-locally policy, applied to Coinbase,
# is a live button whose destination was never registered. The rendered proof
# is test/views/cdp_ramp_kill_switch_test.rb.
class OnrampHelperTest < ActionView::TestCase
  include OnrampHelper

  # cdp_ramp_modal_available? reads logged_in?, which reaches the real views as
  # a controller helper_method. Default it to signed-in so the rail tests below
  # isolate the flag, and steer it explicitly where the session is the subject.
  def logged_in? = @logged_in != false

  # --- dev/test: every rail visible regardless of backend flags ---

  # Coinbase is deliberately absent from this list. It used to be here, and that
  # assertion WAS the defect: it pinned a rail that renders locally while its
  # modal does not, so every non-production render shipped a dead button and the
  # whole suite agreed that was correct.
  test "rails whose destination is a route or a script are visible outside production" do
    with_cdp_ramp(nil) do
      with_coinflow(nil) do
        with_aeropay(nil) do
          swap_provider("none") do
            swap_stripe_enabled(false) do
              %i[coinflow aeropay paypal venmo stripe].each do |rail|
                assert onramp_rail_visible?(rail), "#{rail} should be visible in test env"
              end
            end
          end
        end
      end
    end
  end

  # --- production: each rail gates on its own backend flag ---

  # --- coinbase: the modal's own guard, in every environment ---

  test "coinbase is gated on AppFlags.cdp_ramp? in production" do
    in_production do
      with_cdp_ramp("true") { assert onramp_rail_visible?(:coinbase) }
      with_cdp_ramp(nil)    { assert_not onramp_rail_visible?(:coinbase) }
    end
  end

  test "coinbase is gated on AppFlags.cdp_ramp? OUTSIDE production too" do
    # The kill-switch has no env exemption, so neither may the rail that opens
    # the modal it unregisters. Without this, dev and the test suite render a
    # Coinbase button that swaps to a modal id nothing emitted.
    with_cdp_ramp("true") { assert onramp_rail_visible?(:coinbase) }
    with_cdp_ramp(nil)    { assert_not onramp_rail_visible?(:coinbase) }
  end

  test "coinbase is hidden to a viewer the layout rendered logged out" do
    # wallet-topup and onramp-hub are registered UNGATED so they survive an
    # in-session signup; cdp-ramp is registered under logged_in?. With the flag
    # ON — production today — the rail would otherwise outlive its destination.
    @logged_in = false
    with_cdp_ramp("true") do
      assert_not onramp_rail_visible?(:coinbase)
      in_production { assert_not onramp_rail_visible?(:coinbase) }
    end
  end

  test "cdp_ramp_modal_available? needs BOTH the flag and a session" do
    with_cdp_ramp("true") { assert cdp_ramp_modal_available? }

    with_cdp_ramp(nil) { assert_not cdp_ramp_modal_available?, "the flag alone gates it" }

    @logged_in = false
    with_cdp_ramp("true") { assert_not cdp_ramp_modal_available?, "the session alone gates it" }
  end

  test "coinflow is gated on AppFlags.coinflow? in production" do
    in_production do
      with_coinflow("true") { assert onramp_rail_visible?(:coinflow) }
      with_coinflow(nil)    { assert_not onramp_rail_visible?(:coinflow) }
    end
  end

  test "aeropay is gated on AppFlags.aeropay? in production" do
    in_production do
      with_aeropay("true") { assert onramp_rail_visible?(:aeropay) }
      with_aeropay(nil)    { assert_not onramp_rail_visible?(:aeropay) }
    end
  end

  test "paypal and venmo are gated on Payments.paypal_checkout? in production" do
    in_production do
      swap_paypal_enabled(true) do
        swap_provider("paypal") do
          assert onramp_rail_visible?(:paypal)
          assert onramp_rail_visible?(:venmo)
        end
        swap_provider("stripe") do
          assert_not onramp_rail_visible?(:paypal)
          assert_not onramp_rail_visible?(:venmo)
        end
      end
      swap_paypal_enabled(false) do
        swap_provider("paypal") do
          assert_not onramp_rail_visible?(:paypal)
          assert_not onramp_rail_visible?(:venmo)
        end
      end
    end
  end

  test "stripe is gated on Payments.stripe? in production" do
    in_production do
      swap_provider("stripe") do
        swap_stripe_enabled(true)  { assert onramp_rail_visible?(:stripe) }
        swap_stripe_enabled(false) { assert_not onramp_rail_visible?(:stripe) }
      end
      swap_provider("paypal") do
        swap_stripe_enabled(true) { assert_not onramp_rail_visible?(:stripe) }
      end
    end
  end

  private

  def in_production(&block)
    Rails.env.stub(:production?, true, &block)
  end

  def with_cdp_ramp(value)
    original = ENV["ENABLE_CDP_RAMP"]
    value.nil? ? ENV.delete("ENABLE_CDP_RAMP") : ENV["ENABLE_CDP_RAMP"] = value
    yield
  ensure
    original.nil? ? ENV.delete("ENABLE_CDP_RAMP") : ENV["ENABLE_CDP_RAMP"] = original
  end

  def with_coinflow(value)
    original = ENV["ENABLE_COINFLOW"]
    value.nil? ? ENV.delete("ENABLE_COINFLOW") : ENV["ENABLE_COINFLOW"] = value
    yield
  ensure
    original.nil? ? ENV.delete("ENABLE_COINFLOW") : ENV["ENABLE_COINFLOW"] = original
  end

  def with_aeropay(value)
    original = ENV["ENABLE_AEROPAY"]
    value.nil? ? ENV.delete("ENABLE_AEROPAY") : ENV["ENABLE_AEROPAY"] = value
    yield
  ensure
    original.nil? ? ENV.delete("ENABLE_AEROPAY") : ENV["ENABLE_AEROPAY"] = original
  end

  def swap_provider(value)
    original = Rails.application.config.x.payment_provider
    Rails.application.config.x.payment_provider = value
    yield
  ensure
    Rails.application.config.x.payment_provider = original
  end

  def swap_stripe_enabled(value)
    original = Rails.application.config.x.stripe_enabled
    Rails.application.config.x.stripe_enabled = value
    yield
  ensure
    Rails.application.config.x.stripe_enabled = original
  end

  def swap_paypal_enabled(value)
    original = Rails.application.config.x.paypal_enabled
    Rails.application.config.x.paypal_enabled = value
    yield
  ensure
    Rails.application.config.x.paypal_enabled = original
  end
end
