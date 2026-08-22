require "test_helper"

# Solana::Config.redact_message — redaction for an EXCEPTION MESSAGE, which is a
# different problem from redacting a bare URL.
#
# Why it had to exist: `redact_rpc_url` is a URL redactor. Fed a SENTENCE it
# raises inside URI.parse and returns "***", so the only safe way to print an
# exception was to print nothing useful. Two classes on the credential-rotation
# path put the whole endpoint inside their message —
# Solana::Client::InsecureRpcUrlError interpolates `@rpc_url.inspect`, and
# URI::InvalidURIError quotes the bad URI back — and those messages were being
# interpolated raw into the boot guard's ERROR line and into `solana:health`.
class Solana::ConfigRedactMessageTest < ActiveSupport::TestCase
  # Obviously fake, and shaped like a provider key (long, opaque, hyphenated) so
  # it exercises the same `opaque_token?` rule a real one would.
  SENTINEL_KEY = "SENTINEL-NOT-A-REAL-KEY-0000".freeze
  SENTINEL_URL = "https://rpc.example.test/?api-key=#{SENTINEL_KEY}".freeze

  test "masks a credentialed URL embedded in a sentence" do
    message = "Solana::Client requires an https:// RPC URL (got \"#{SENTINEL_URL}\"). Plain http:// is only allowed for localhost."

    out = Solana::Config.redact_message(message, url: SENTINEL_URL)

    refute_includes out, SENTINEL_KEY, "the credential survived redaction"
    assert_includes out, "api-key=***", "the operator still needs WHICH param carried it"
  end

  test "keeps the sentence readable — the whole reason redact_rpc_url could not do this" do
    out = Solana::Config.redact_message(
      "Solana::Client requires an https:// RPC URL (got \"#{SENTINEL_URL}\").",
      url: SENTINEL_URL
    )

    refute_equal "***", out, "redact_rpc_url's behaviour on a sentence — the diagnostic is destroyed"
    assert_includes out, "requires an https:// RPC URL",
                    "the operator must still be told WHAT was wrong with the endpoint"
  end

  test "masks the configured credential even when it is not inside a parseable URL" do
    # A mangled endpoint is exactly the input this path exists to diagnose, and
    # a stray space strands the key outside any URL the regex can match. The
    # literal-fragment pass is what catches it.
    message = "bad URI(is not URI?): \"https:// rpc.example.test/?api-key=#{SENTINEL_KEY}\""

    out = Solana::Config.redact_message(message, url: SENTINEL_URL)

    refute_includes out, SENTINEL_KEY, "the credential survived a malformed-URL message"
  end

  test "masks an opaque PATH-segment key, not just a query value" do
    path_url = "https://rpc.example.test/v2/#{SENTINEL_KEY}"

    out = Solana::Config.redact_message("connection refused for #{path_url}", url: path_url)

    refute_includes out, SENTINEL_KEY
    assert_includes out, "v2", "short, non-secret path segments must stay legible"
  end

  test "masks userinfo credentials" do
    url = "https://someuser:#{SENTINEL_KEY}@rpc.example.test/"

    out = Solana::Config.redact_message("bad URI(is not URI?): #{url}", url: url)

    refute_includes out, SENTINEL_KEY
  end

  test "scrubs invalid UTF-8 instead of raising ArgumentError from a rescue clause" do
    # The PR-392 fix, in this helper: every caller invokes it from INSIDE a
    # rescue clause, where a raise is not caught. A latin-1 error page quoted
    # back by the JSON parser puts an invalid byte in e.message; gsub on that
    # raises. scrub must come FIRST.
    dirty = "unexpected token \xFF\xFE at line 1".dup.force_encoding("UTF-8")
    refute dirty.valid_encoding?, "fixture must actually be invalid UTF-8"

    out = nil
    assert_nothing_raised { out = Solana::Config.redact_message(dirty, url: SENTINEL_URL) }
    assert_includes out, "unexpected token"
  end

  test "collapses whitespace so an upstream body cannot forge log lines" do
    out = Solana::Config.redact_message("line one\nFATAL: forged\tline", url: SENTINEL_URL)

    refute_includes out, "\n", "a newline lets an untrusted body write its own log line"
    assert_equal "line one FATAL: forged line", out
  end

  test "handles a blank message and a blank configured url" do
    assert_equal "", Solana::Config.redact_message(nil, url: SENTINEL_URL)
    assert_equal "boom", Solana::Config.redact_message("boom", url: "")
  end
end
