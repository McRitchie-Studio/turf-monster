require "test_helper"
require "open3"
require "json"

# [unit] The signing hop's redirect_link, EXECUTED against the real view source.
#
# THE DEFECT THIS PINS, measured 2026-09-09 against solana-studio 0.9.2 and
# studio-engine 0.74.6. A cold mobile session takes two hops — connect, then
# sign — and walletOps builds the second one inside resume():
#
#     signingHop(provider, connected.journal, {
#       redirectLink: opts.redirectLink || journal.redirectLink
#     })
#
# NEITHER side of that `||` exists in production. The page a wallet returns to is
# studio-engine's solana_sessions/phantom_callback, and it calls
# `walletOps.resume(params, { navigate: … })` — no redirectLink. redirect_provider's
# beginConnect journals dappSecretKey, dappPublicKey and intent — no redirect link.
# walletTransport's query builder drops undefined values silently, so the
# signTransaction deeplink went out as
# [dapp_encryption_public_key, nonce, payload] and Phantom's docs list
# redirect_link as REQUIRED. The user approves inside their wallet and the wallet
# has nowhere to send the signed bytes.
#
# WHY NOTHING CAUGHT IT. solana-studio's own round-trip suite passes
# `redirectLink: 'https://a.test/cb'` to resume() itself — it manufactures the
# exact parameter production omits. That is the shape of failure this task
# exists to close, and it is why the assertion below drives the wrapper with the
# ENGINE'S OWN CALL — `{ navigate: fn }` and nothing else.
#
# RUN, NOT GREPPED. The wrapper is lifted out of the partial verbatim and
# executed in node, because "defaults a missing option without clobbering a
# supplied one" is behaviour, and a source-text assertion cannot see it.
class WalletResumeRedirectLinkJsTest < ActiveSupport::TestCase
  PARTIAL = Rails.root.join("app/views/shared/_contest_entry_intent.html.erb")

  # The registration IIFE, lifted verbatim — the wrapper lives inside it, so a
  # refactor that moves it out of the IIFE fails here rather than silently
  # stopping being tested.
  def registration_source
    src = File.read(PARTIAL)
    start = src.index("(function () {\n  var S = window.SolanaStudio;")
    assert start, "could not find the intent registration IIFE in the partial"
    finish = src.index("})();", start)
    assert finish, "could not bound the registration IIFE"
    src[start..(finish + 4)]
  end

  # `location` is the document the wallet redirected TO. `resume_opts` is the
  # literal second argument the callback page hands resume().
  def run_resume(resume_opts:, location: { origin: "https://turf.test", pathname: "/auth/phantom/callback" })
    script = <<~JS
      global.window = global;
      window.location = #{location.to_json};
      var seen = [];
      var installs = 0;
      window.SolanaStudio = {
        walletOps: {
          define: function () {},
          resume: function (params, opts) {
            installs++;
            seen.push({ params: params, opts: opts });
            return Promise.resolve('inner');
          }
        }
      };
      #{registration_source}
      // Render the partial TWICE — the layout renders it once per document, but
      // a host that registers it in two places must not double-wrap.
      #{registration_source}
      var out = window.SolanaStudio.walletOps.resume({ nonce: 'N', data: 'D' }, #{resume_opts});
      out.then(function (value) {
        process.stdout.write(JSON.stringify({
          value: value,
          calls: seen.length,
          params: seen[0] && seen[0].params,
          opts: seen[0] && seen[0].opts && {
            redirectLink: seen[0].opts.redirectLink,
            keys: Object.keys(seen[0].opts).sort()
          }
        }));
      });
    JS

    stdout, stderr, status = Open3.capture3("node", "--eval", script)
    assert status.success?, "node failed: #{stderr}"
    JSON.parse(stdout)
  end

  test "the engine's own resume call gets a redirect_link it never passed" do
    # THIS IS THE PRODUCTION CALL, verbatim from studio-engine 0.74.6's
    # solana_sessions/phantom_callback.html.erb:
    #   studio.walletOps.resume(params, { navigate: function(url) { … } });
    result = run_resume(resume_opts: "{ navigate: function () {} }")

    assert_equal 1, result["calls"], "the wrapper must call through exactly once"
    assert_equal "https://turf.test/auth/phantom/callback", result.dig("opts", "redirectLink"),
                 "without this the signing hop's deeplink omits redirect_link entirely"
    assert_equal %w[navigate redirectLink], result.dig("opts", "keys"),
                 "the caller's own options must survive alongside the default"
    assert_equal "inner", result["value"], "the wrapper must return what walletOps returns"
  end

  test "the default is the document the wallet actually returned to" do
    # NOT a configured path and NOT a re-derived route: origin + pathname of the
    # page this code is running on. resume() is only called with a pending
    # journal, which only happens on a document a wallet redirected to — so this
    # value IS the redirect_link that worked one hop earlier. A host that mounts
    # the callback elsewhere is right by construction, which a hardcoded
    # "/auth/phantom/callback" would not be.
    result = run_resume(
      resume_opts: "{ navigate: function () {} }",
      location: { origin: "https://other.example", pathname: "/wallet/return" }
    )

    assert_equal "https://other.example/wallet/return", result.dig("opts", "redirectLink")
  end

  test "a caller that supplies its own redirect_link outranks the default" do
    # A DEFAULT, NOT AN OVERRIDE. When solana-studio journals the redirect link
    # (the real fix) or a host starts passing its own, this wrapper must get out
    # of the way rather than fight it — otherwise retiring it becomes a bug hunt.
    result = run_resume(resume_opts: "{ navigate: function () {}, redirectLink: 'https://elsewhere.test/cb' }")

    assert_equal "https://elsewhere.test/cb", result.dig("opts", "redirectLink")
  end

  test "resume's first argument is passed through untouched" do
    # The wrapper copies the OPTIONS. The params carry the wallet's encrypted
    # answer, and a copy of those would be a second place for a key to go
    # missing — so they must arrive by reference, unchanged.
    result = run_resume(resume_opts: "{ navigate: function () {} }")

    assert_equal({ "nonce" => "N", "data" => "D" }, result["params"])
  end

  test "a page with no resume to wrap installs nothing and throws nothing" do
    # GUARDED like every optional capability in this app: a consumer that never
    # loaded solana_studio/wallet_ops.js has no resume, and an absent capability
    # must not default to the permissive branch.
    script = <<~JS
      global.window = global;
      window.location = { origin: "https://turf.test", pathname: "/" };
      window.SolanaStudio = { walletOps: { define: function () {} } };
      #{registration_source}
      process.stdout.write(JSON.stringify({
        resume: typeof window.SolanaStudio.walletOps.resume,
        flagged: !!window.SolanaStudio.walletOps.tmRedirectLinkDefaulted
      }));
    JS

    stdout, stderr, status = Open3.capture3("node", "--eval", script)
    assert status.success?, "node failed: #{stderr}"
    result = JSON.parse(stdout)

    assert_equal "undefined", result["resume"], "the wrapper must not invent a resume"
    assert_equal false, result["flagged"]
  end
end
