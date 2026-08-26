require "test_helper"

# [unit] The debug logger must not ship a live credential reader to production.
#
# TWO SEPARATE GUARANTEES, and neither substitutes for the other:
#   1. It defaults OFF outside development/QA — protecting the user who never
#      opens DevTools, which is nearly all of them.
#   2. Secrets are redacted even when it IS on — protecting the operator
#      debugging QA, and anyone screen-sharing a console.
#
# Driven in Node against the real module rather than asserted on source text: the
# question is what the functions DO with a body, and a grep for "redact" would pass
# on a redactor that returns its input unchanged.
class DebugNetGuardJsTest < ActiveSupport::TestCase
  SOURCE = Rails.root.join("app/javascript/debug_logger.js")

  # Evaluate the module's helpers in a bare Node context with a stubbed document,
  # then run `expr`. Only the helper definitions are needed, so the file is loaded
  # with its side-effecting patchers neutered by a minimal window/document shim.
  def evaluate(expr, environment:)
    harness = <<~JS
      const src = require('fs').readFileSync(#{SOURCE.to_s.inspect}, 'utf8');
      global.window = { fetch: () => {}, addEventListener: () => {} };
      global.document = { body: { dataset: { appEnvironment: #{environment.nil? ? 'undefined' : environment.inspect} } },
                          addEventListener: () => {} };
      global.performance = { now: () => 0 };
      // Expose the helpers without running the IIFE patchers below them.
      const head = src.split('// \\u2500\\u2500 Web3')[0];
      eval(head);
      console.log(JSON.stringify(#{expr}));
    JS
    out = IO.popen(["node", "-e", harness], &:read)
    raise "node failed for #{environment}: #{out}" unless $?.success?

    JSON.parse(out)
  end

  test "the logger defaults OFF in production" do
    assert_equal false, evaluate("window.DEBUG_NET", environment: "production"),
      "a traffic logger that defaults on in production prints live signatures and " \
      "CSRF tokens to any console that happens to be open"
  end

  test "it defaults ON in development and QA, where operators use it" do
    assert_equal true, evaluate("window.DEBUG_NET", environment: "development")
    assert_equal true, evaluate("window.DEBUG_NET", environment: "qa"),
      "QA runs Rails.env=production on Heroku — keying off Rails.env alone would " \
      "disable the tooling exactly where operators need it"
  end

  test "an unreadable environment defaults OFF, not on" do
    assert_equal false, evaluate("window.DEBUG_NET", environment: nil),
      "an unknown env is not a licence to log credentials"
  end

  test "the signature and the SIWS message are redacted from a logged body" do
    body = { message: "sign in nonce abc", signature: "5xBASE58SIGNATURExx",
             pubkey: "9xPUBKEY", wallet_provider: "Phantom" }.to_json
    logged = evaluate("_safeBody(#{body.inspect})", environment: "development")
    parsed = JSON.parse(logged)

    assert_equal "[redacted]", parsed["signature"], "the base58 signature is a live credential"
    assert_equal "[redacted]", parsed["message"], "the SIWS message carries the nonce it signs"
    assert_equal "9xPUBKEY", parsed["pubkey"], "a public key is public — over-redacting makes the tool useless"
    assert_equal "Phantom", parsed["wallet_provider"]
  end

  test "a CSRF token is redacted from a response body" do
    logged = evaluate("_safeBody(#{{ csrf_token: "LIVE-TOKEN", mode: "web3" }.to_json.inspect})",
                      environment: "development")

    assert_equal "[redacted]", JSON.parse(logged)["csrf_token"]
    assert_equal "web3", JSON.parse(logged)["mode"]
  end

  test "a nested secret is redacted too" do
    body = { data: { user: { signature: "DEEP" } } }.to_json
    parsed = JSON.parse(evaluate("_safeBody(#{body.inspect})", environment: "development"))

    assert_equal "[redacted]", parsed.dig("data", "user", "signature"),
      "a flat key check misses everything an API nests"
  end

  test "a non-JSON body passes through untouched rather than being swallowed" do
    assert_equal "user=alex&x=1",
                 evaluate("_safeBody('user=alex&x=1')", environment: "development"),
      "a form post has no keys to check; dropping it would blind the tool"
  end
end
