require "test_helper"

# [unit] Rack::Attack sits in the middleware stack ONCE (/tasks/turf-navbar-polish).
#
# rack-attack 6.x registers itself: its Railtie's "rack-attack.middleware"
# initializer runs `app.middleware.use(Rack::Attack)`. The app's own
# initializer used to say the same line again, so the stack held two
# instances, one before OmniAuth::Builder and one after it. The second never
# counted anything (Rack::Attack#call skips a request whose env already carries
# "rack.attack.called"), so it was a dead layer on every request and a trap for
# whoever reads the stack to find where the throttles run.
#
# The one that stays is the Railtie's, BEFORE OmniAuth: that is where the
# throttles already ran, and it keeps OmniAuth's request phase (/auth/*)
# behind them.
class RackAttackMiddlewareTest < ActiveSupport::TestCase
  def stack
    Rails.application.middleware.map(&:klass)
  end

  test "Rack::Attack is registered exactly once" do
    assert_equal 1, stack.count(Rack::Attack), "middleware stack: #{stack.map(&:to_s).inspect}"
  end

  test "it runs before OmniAuth, where the throttles always ran" do
    attack = stack.index(Rack::Attack)
    omniauth = stack.index(OmniAuth::Builder)

    assert attack, "Rack::Attack is missing from the middleware stack"
    assert omniauth, "OmniAuth::Builder is missing from the middleware stack"
    assert_operator attack, :<, omniauth
  end
end
