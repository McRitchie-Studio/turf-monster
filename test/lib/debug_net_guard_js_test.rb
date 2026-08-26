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

  # THE SHAPE THIS APP ACTUALLY PUTS ON THE WIRE.
  #
  # This test used to assert redaction of `csrf_token` — a key turf-monster never
  # emits. accounts_controller.rb:90 renders
  # `client_session_payload.merge(csrf: form_authenticity_token)`, a BARE `csrf`.
  # So the suite was green while every visibilitychange rehydrate printed a live
  # token. A redactor proved against a fictional key proves nothing; the payload
  # in this test is now copied from the controller, not invented.
  test "the CSRF token this app really renders is redacted" do
    real_payload = { mode: "web3", loggedIn: true, csrf: "LIVE-TOKEN" }.to_json
    parsed = JSON.parse(evaluate("_safeBody(#{real_payload.inspect})", environment: "development"))

    assert_equal "[redacted]", parsed["csrf"],
      "accounts_controller.rb:90 emits `csrf`, not `csrf_token` — this is the key on the wire"
    assert_equal "web3", parsed["mode"], "non-secret fields must still be readable"
  end

  test "the auth nonce is redacted — it is the half the signature is over" do
    body = { nonce: "a1b2c3d4e5f6" }.to_json   # solana_sessions_controller.rb:8
    parsed = JSON.parse(evaluate("_safeBody(#{body.inspect})", environment: "development"))

    assert_equal "[redacted]", parsed["nonce"],
      "the nonce is single-use, but printing it beside the message it signs hands " \
      "over both halves of the challenge in one screen-share"
  end

  test "a signed transaction is redacted — anyone holding it can submit it" do
    body = { signed_tx: "AQABBBBASE64SIGNEDTX" }.to_json
    parsed = JSON.parse(evaluate("_safeBody(#{body.inspect})", environment: "development"))

    assert_equal "[redacted]", parsed["signed_tx"]
  end

  # THE OTHER HALF OF THE CONTRACT. A logger that hides the transaction id cannot
  # debug a transaction, so over-redaction is its own failure — asserted, not assumed.
  test "public on-chain identifiers stay visible" do
    body = { tx_signature: "5xTXSIG", sent_signature: "5xSENTSIG", tokens: 3 }.to_json
    parsed = JSON.parse(evaluate("_safeBody(#{body.inspect})", environment: "development"))

    assert_equal "5xTXSIG", parsed["tx_signature"], "a tx signature is a public block-explorer id"
    assert_equal "5xSENTSIG", parsed["sent_signature"], "so is a sent signature"
    assert_equal 3, parsed["tokens"],
      "`tokens` (plural) is the entry-token COUNT, not a credential — only bare `token` is"
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
