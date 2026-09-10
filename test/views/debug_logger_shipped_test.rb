require "test_helper"

# [component] The debug logger has to REACH the browser before its retry matters.
#
# The fix this pins lives in app/javascript/debug_logger.js: the Phantom patcher
# keeps retrying for a wallet that is injected AFTER page load. e2e/phantom_debug_retry
# .spec.js proves that retry actually runs in a browser. This test covers the
# failure that would make that spec's subject unreachable in the first place —
# the module never being SERVED.
#
# It is deliberately not a token grep. The importmap is rendered as JSON, so the
# assertion parses it and demands a real digested asset path: an importmap that
# still names debug_logger but maps it to nothing is exactly the silent break,
# and a substring test would call that green.
class DebugLoggerShippedTest < ActionDispatch::IntegrationTest
  setup { log_in_as(users(:alex)) }

  test "the importmap the page renders maps debug_logger to a real asset" do
    get root_path
    follow_redirect! while response.redirect?
    assert_response :success

    json = css_select("script[type='importmap']").first
    assert json, "the page renders no importmap — nothing in app/javascript loads at all"

    imports = JSON.parse(json.text).fetch("imports")
    path = imports["debug_logger"]

    assert path, "debug_logger left the importmap; the Phantom retry is no longer served " \
                 "to any browser, and only the e2e lane would notice"
    assert_match %r{\A/assets/debug_logger-\w+\.js\z}, path,
      "debug_logger is pinned but resolves to #{path.inspect} — a name with no asset " \
      "behind it fails at import time in the browser, silently, on every page"
  end

  # The other half of the chain. A pin nothing imports ships nothing.
  test "application.js imports the module the importmap pins" do
    source = Rails.root.join("app/javascript/application.js").read

    assert_match(/^import ["']debug_logger["']/, source,
      "nothing imports debug_logger, so the pin above is decoration and the retry never runs")
  end
end
