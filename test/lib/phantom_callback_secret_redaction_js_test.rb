require "test_helper"
require "open3"

# The SECOND guard on the Phantom callback secret leak. The first — not
# rendering the sink on a real production deploy — is pinned by
# test/integration/phantom_callback_debug_gate_test.rb. This one covers the case
# that guard deliberately allows: QA and development, where the sink DOES render
# and an operator is looking at the screen.
#
# `phantom_dl_secret` is set by phantom_deeplink.js:38 to
# encodeBase58(dappKeyPair.secretKey) — a real private key. Its VALUE must never
# be printed, in any environment.
#
# WHY THIS RUNS THE REAL JS RATHER THAN GREPPING THE SOURCE: a source-text
# assertion cannot tell a live redaction branch from a dead one, and this house
# has been bitten by exactly that. So the dump loop is extracted from the view
# and executed against a stubbed localStorage holding a known sentinel secret;
# the assertion is that the sentinel never appears in anything dbg() emitted.
#
# NOTE ON ALL_KEYS: it deliberately still CONTAINS phantom_dl_secret, because
# cleanup() iterates it to REMOVE the keys from localStorage. Pruning the secret
# from that list would strand the private key on the device forever — a worse
# bug than the one being fixed. Redaction happens at the point of display.
class PhantomCallbackSecretRedactionJsTest < ActiveSupport::TestCase
  SENTINEL = "SECRET-DO-NOT-PRINT-4f3a9c1e8b7d2065".freeze

  def dump_loop_source
    view = Rails.root.join("app/views/solana_sessions/phantom_callback.html.erb").read
    # Pull the two declarations and the dump loop out of the view verbatim, so
    # the test executes the shipped code rather than a paraphrase of it.
    all_keys   = view[/var ALL_KEYS = \[.*?\];/m]
    secret_key = view[/var SECRET_KEYS = \[.*?\];/m]
    loop_body  = view[/dbg\('--- localStorage ---'\);.*?\n  \}\);/m]
    assert all_keys,   "could not extract ALL_KEYS from the view"
    assert secret_key, "could not extract SECRET_KEYS from the view — is redaction still there?"
    assert loop_body,  "could not extract the localStorage dump loop from the view"
    [all_keys, secret_key, loop_body].join("\n")
  end

  test "the dapp secret key value never reaches the debug sink" do
    script = <<~JS
      var emitted = [];
      function dbg(label, value) { emitted.push(String(label) + ' ' + String(value)); }
      function truncate(s, n) { return s && s.length > n ? s.substring(0, n) + '...' : s; }
      var store = {
        phantom_dl_secret: #{SENTINEL.inspect},
        phantom_dl_pubkey: 'PUBKEY-fine-to-print',
        phantom_dl_nonce: 'NONCE-fine',
        phantom_dl_nonce_at: '123',
        phantom_dl_step: 'connect',
        phantom_dl_link_mode: 'deeplink',
        phantom_dl_cluster: 'mainnet-beta',
        phantom_dl_age_attested: 'true'
      };
      var localStorage = { getItem: function (k) { return Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null; } };

      #{dump_loop_source}

      console.log(JSON.stringify({ emitted: emitted }));
    JS

    out, err, status = Open3.capture3("node", "-e", script)
    assert status.success?, "node failed: #{err}"
    emitted = JSON.parse(out.lines.last)["emitted"]

    joined = emitted.join("\n")
    refute_includes joined, SENTINEL,
                    "the dapp secret key VALUE reached the debug sink:\n#{joined}"
    # Truncation is not redaction: a 40-char prefix of a private key is still key
    # material, so assert no prefix of it leaked either.
    refute_includes joined, SENTINEL[0, 16],
                    "a PREFIX of the secret reached the sink — truncate() is not a redactor"

    # The control: non-secret keys must still print, or "nothing leaked" would be
    # trivially true and this test would pass against a sink that prints nothing.
    assert_includes joined, "PUBKEY-fine-to-print",
                    "non-secret values must still be printed, otherwise this test is vacuous"
    # And the operator still learns the secret is present.
    assert_match(/redacted/, joined, "the operator should still see that a secret exists")
  end
end
