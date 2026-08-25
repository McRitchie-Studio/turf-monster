require "test_helper"
require "open3"

# The Phantom debug patcher's retry loop, exercised in Node against the real
# module — the same harness idea as wallet_account_change_js_test.
#
# THE DEFECT: attach() returned TRUE when `walletProvider.get('phantom')` was
# null, and the driver does `if (attach()) return;` BEFORE starting its interval.
# Phantom injects asynchronously, so null is the ORDINARY state during the very
# window the retry exists to wait out — the loop never started, and the
# instrumentation silently never attached. Diagnostic-only, but this is the
# tooling you reach for to debug Phantom, so it went missing exactly when wanted.
class PhantomDebugRetryJsTest < ActiveSupport::TestCase
  test "the patcher survives Phantom's injection window and attaches late" do
    source = Rails.root.join("app/javascript/debug_logger.js")
    script = <<~'JS'
      import { pathToFileURL } from 'node:url';

      // Phantom is ABSENT at import time — the real timing this exists for.
      let phantom = null;
      const provider = { get: (n) => (n === 'phantom' ? phantom : null) };

      // The module registers SEVERAL retry drivers (phantom, solanaWeb3, ...).
      // Keeping only the last would test whichever registered last, not this one.
      const intervals = [];
      globalThis.window = {
        walletProvider: provider,
        addEventListener() {}, removeEventListener() {},
        location: { href: '/' }, localStorage: { getItem: () => null, setItem() {} }
      };
      globalThis.document = { addEventListener() {}, readyState: 'complete', documentElement: {} };
      globalThis.performance = { now: () => 0 };
      globalThis.setInterval = (fn) => { intervals.push(fn); return intervals.length; };
      const cleared = [];
      globalThis.clearInterval = (id) => { if (id) { cleared.push(id); intervals[id - 1] = null; } };
      globalThis.setTimeout = (fn) => { try { fn(); } catch (e) {} return 1; };

      await import(pathToFileURL(process.argv[1]).href + '?t=' + Date.now());

      // THE CLAIM: absent Phantom must leave a live retry, not a stopped one.
      const startedRetry = intervals.some((f) => f !== null);

      // Phantom arrives, as it does a few hundred ms into a real page load.
      phantom = { connect() {}, signMessage() {}, signTransaction() {} };
      intervals.forEach((f) => { if (f) { try { f(); } catch (e) {} } });

      console.log(JSON.stringify({
        startedRetry,
        patchedAfterInjection: !!phantom.__debugPatched,
        retryClearedAfterAttach: cleared.length > 0
      }));
    JS

    stdout, stderr, status = Open3.capture3("node", "--input-type=module", "--eval", script, source.to_s)
    assert status.success?, stderr
    # The module prints its own [debug-net] banner, so take the LAST line — the
    # payload — rather than assuming stdout holds only ours.
    result = JSON.parse(stdout.lines.map(&:strip).reject(&:empty?).last)

    assert result.fetch("startedRetry"),
           "an absent Phantom must return FALSE so the driver starts its interval — returning " \
           "true reports 'done' during the injection window and the loop never runs"
    assert result.fetch("patchedAfterInjection"),
           "once Phantom appears the retry must actually patch it"
    assert result.fetch("retryClearedAfterAttach"),
           "and stop retrying once it has — a live interval forever is its own defect"
  end
end
