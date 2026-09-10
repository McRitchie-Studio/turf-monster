require "test_helper"

# The Phantom deeplink callback shipped a visual debug sink that printed
# localStorage — including `phantom_dl_secret`, which the deep link
# (solana_studio/_phantom_deeplink) sets to encodeBase58(dappKeyPair.secretKey),
# a real private key — to an on-page element AND the console, with NO
# environment gate, on every mobile Phantom sign-in.
#
# Two independent guards, and this file pins the server half:
#   1. the sink is not RENDERED on a real production deploy (here), and
#   2. the secret's VALUE is redacted even when it is (see
#      test/lib/phantom_callback_secret_redaction_js_test.rb).
#
# AppFlags.live_production? is production-AND-not-QA — the same predicate the
# OPSEC-020 kill-switches use — so QA keeps its debugging. Stubbing it is the
# only way to reach the production branch from the test env, where
# Rails.env.production? is false by construction.
#
# 2026-08-30 (adopt-engine-phantom-deeplink): THE VIEW IS THE ENGINE'S NOW, and
# these assertions did not move BECAUSE they never read a file — they read the
# response to a real request, so they follow the template wherever it resolves.
# What DID move is the predicate behind the render: the engine gates on
# Studio.wallet_debug_sink and DEFAULTS IT OFF, and config/initializers/studio.rb
# opts this app back in with `-> { !AppFlags.live_production? }`. Delete that one
# line and the second test below — the control — is what fails.
class PhantomCallbackDebugGateTest < ActionDispatch::IntegrationTest
  test "a real production deploy renders no debug sink at all" do
    AppFlags.stub :live_production?, true do
      get "/auth/phantom/callback"

      assert_response :success
      assert_no_match(/id="phantom-log"/, response.body,
                      "the debug sink must not render on a real production deploy")
      assert_no_match(/Debug Log/, response.body,
                      "the sink's heading leaks its presence even if the id changes")
    end
  end

  test "outside real production the sink still renders, so the guard is not always-off" do
    AppFlags.stub :live_production?, false do
      get "/auth/phantom/callback"

      assert_response :success
      assert_match(/id="phantom-log"/, response.body,
                   "QA and development must keep the debug sink — this is the control " \
                   "that proves the production assertion above is discriminating, not vacuous")
    end
  end

  test "the script survives the sink being absent" do
    # The regression that would have been introduced by removing the div alone:
    # dbg() wrote to logEl unconditionally, so an absent sink would throw a
    # TypeError on the first call and break Phantom sign-in outright. The guard
    # must short-circuit BEFORE touching the DOM.
    AppFlags.stub :live_production?, true do
      get "/auth/phantom/callback"

      assert_match(/if \(!DEBUG_SINK\) \{ return; \}/, response.body,
                   "dbg() must no-op when the sink is absent, or removing the div " \
                   "breaks the callback instead of just quieting it")
    end
  end
end
