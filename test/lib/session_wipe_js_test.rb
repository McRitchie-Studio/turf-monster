require "test_helper"
require "json"
require "open3"

# wipeClientState is browser JavaScript, but its contract is small enough to
# exercise in Node: clear both stores, keep exactly the two device preferences,
# survive a storage accessor that throws, and tell sibling tabs.
#
# THE ALLOW-LIST IS THE POINT. The server half of this slice deleted two
# deny-lists that leaked seven keys between them; a test that names the keys it
# expects to be gone would repeat that mistake. So the assertion is "everything
# except the named survivors is gone", which a key added tomorrow cannot slip past.
class SessionWipeJsTest < ActiveSupport::TestCase
  def run_harness(script)
    source = Rails.root.join("app/javascript/session_wipe.js")
    stdout, stderr, status = Open3.capture3(
      "node", "--input-type=module", "--eval", script, source.to_s
    )
    assert status.success?, stderr
    JSON.parse(stdout)
  end

  test "the wipe clears both stores and keeps only the device preferences" do
    result = run_harness(<<~'JS')
      import { pathToFileURL } from 'node:url';

      function makeStore(seed) {
        const data = Object.assign({}, seed);
        return {
          getItem: (k) => (k in data ? data[k] : null),
          setItem: (k, v) => { data[k] = String(v); },
          removeItem: (k) => { delete data[k]; },
          clear: () => { Object.keys(data).forEach((k) => delete data[k]); },
          _dump: () => Object.assign({}, data)
        };
      }

      // Every key the audit found, plus the two device preferences.
      globalThis.localStorage = makeStore({
        theme: 'light', devMode: 'true',
        inviter_slug: 'someone', lastUserId: '42',
        pendingContestEntry: '{}', seedsNavbar: '{}', seedsLevelUp: '{}',
        phantom_dl_secret: 's', phantom_dl_pubkey: 'p', phantom_dl_nonce: 'n',
        phantom_dl_nonce_at: '1', phantom_dl_step: 'signIn',
        phantom_dl_link_mode: 'false', phantom_dl_cluster: 'devnet',
        phantom_dl_user_id: '42', phantom_dl_age_attested: '1'
      });
      globalThis.sessionStorage = makeStore({
        pendingAuthStep: 'x', walletSetupAutoConnect: '1', walletSetupReopen: '1'
      });

      const posted = [];
      globalThis.BroadcastChannel = class {
        constructor(name) { this.name = name; }
        postMessage(msg) { posted.push({ name: this.name, msg }); }
        addEventListener() {}
        close() {}
      };
      globalThis.window = {};

      const mod = await import(pathToFileURL(process.argv[1]).href + '?t=' + Date.now());
      mod.wipeClientState();

      console.log(JSON.stringify({
        local: localStorage._dump(),
        session: sessionStorage._dump(),
        posted,
        globalised: typeof window.wipeClientState === 'function'
      }));
    JS

    assert_equal({ "theme" => "light", "devMode" => "true" }, result.fetch("local"),
                 "localStorage must retain EXACTLY the two device preferences and nothing else. " \
                 "Anything else surviving is state the next visitor to this browser inherits.")

    assert_empty result.fetch("session"),
                 "sessionStorage carries only in-flight session state (pendingAuthStep, the " \
                 "wallet-setup reopen flags) — none of it may survive a logout"

    posted = result.fetch("posted")
    assert_equal 1, posted.size, "sibling tabs must be told exactly once"
    assert_equal "tm-session", posted.first.fetch("name")
    assert_equal "logout-wipe", posted.first.dig("msg", "type")

    assert result.fetch("globalised"),
           "the helper must be on window — the logout links call it from an inline onclick"
  end

  test "a throwing storage accessor does not abort the rest of the wipe" do
    result = run_harness(<<~'JS')
      import { pathToFileURL } from 'node:url';

      // Private mode: localStorage.clear() throws. sessionStorage still must be
      // wiped — a HALF-DONE wipe is the exact failure this function prevents.
      globalThis.localStorage = {
        getItem: () => null,
        setItem: () => { throw new Error('QuotaExceededError'); },
        clear: () => { throw new Error('SecurityError'); }
      };
      const sessionData = { pendingAuthStep: 'x', walletSetupReopen: '1' };
      globalThis.sessionStorage = {
        getItem: (k) => (k in sessionData ? sessionData[k] : null),
        setItem: (k, v) => { sessionData[k] = v; },
        clear: () => { Object.keys(sessionData).forEach((k) => delete sessionData[k]); },
        _dump: () => Object.assign({}, sessionData)
      };
      globalThis.BroadcastChannel = class {
        constructor() {} postMessage() {} addEventListener() {} close() {}
      };
      globalThis.window = {};

      const mod = await import(pathToFileURL(process.argv[1]).href + '?t=' + Date.now());
      let threw = false;
      try { mod.wipeClientState(); } catch (e) { threw = true; }

      console.log(JSON.stringify({ threw, session: sessionStorage._dump() }));
    JS

    assert_equal false, result.fetch("threw"),
                 "the wipe must not propagate a storage error — a logout that 500s the click " \
                 "leaves the user MORE logged in than before"
    assert_empty result.fetch("session"),
                 "sessionStorage must still be cleared when localStorage throws. Wiping each " \
                 "store independently is what makes that true."
  end
end
