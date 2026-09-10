require "test_helper"

# [integration] The attribute the debug-logger guard reads must actually render.
#
# debug_logger.js decides whether to default ON by reading
# document.body.dataset.appEnvironment. That makes this attribute load-bearing for
# a SECURITY control, not just a display hint: if the layout stops rendering it, or
# renders "development" in production, the logger silently starts printing live
# signatures and CSRF tokens again.
#
# The unit test drives the JS against a stubbed dataset, so it cannot see whether
# the real page supplies one. This closes that seam.
class DebugNetEnvironmentTest < ActionDispatch::IntegrationTest
  setup { log_in_as(users(:alex)) }

  test "every rendered page carries the environment the guard keys off" do
    get root_path
    follow_redirect! while response.redirect?
    assert_response :success

    body = css_select("body").first
    assert body, "no body element rendered"

    env = body["data-app-environment"]
    assert env.present?,
      "debug_logger.js reads document.body.dataset.appEnvironment to decide whether to " \
      "default ON. A missing attribute is read as undefined — which fails CLOSED today, " \
      "but silently removes the only signal the guard has"
    assert_equal Rails.env.to_s, env,
      "the test env must render as itself; a page claiming 'development' turns the " \
      "logger on wherever it renders"
  end

  # The QA distinction is the whole reason this reads an attribute rather than
  # Rails.env: QA runs Rails.env=production on Heroku, so a Rails.env check would
  # call QA production and disable the tooling exactly where operators use it.
  test "a QA deployment reports qa, not production" do
    AppFlags.stub :qa_environment?, true do
      get root_path
      follow_redirect! while response.redirect?

      assert_equal "qa", css_select("body").first["data-app-environment"],
        "QA must be distinguishable from production or the logger is off where it is needed"
    end
  end
end
