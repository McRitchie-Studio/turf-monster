require "test_helper"
require "open3"
require "json"

# [unit] The celebration relay's codec, EXECUTED against the real view source.
#
# WHY THIS EXISTS AS ITS OWN TIER. The relay is the one part of the redirect
# transport's return leg that touches storage, and every property that makes it
# safe is a property of storage handling: single-use, expiring, kind-scoped, and
# silent when the store refuses. None of those is visible in a source-text
# assertion and none of them needs a browser, so they are driven here, directly,
# where a failure names the property rather than "the round trip did not finish".
#
# THE FAILURE MODE EACH ONE GUARDS is a party thrown at the wrong time:
#   - not single-use  -> a reload congratulates you again for the same entry
#   - not expiring    -> tomorrow's page load celebrates yesterday's entry
#   - not kind-scoped -> one flow paints another flow's payload
#   - not silent      -> a Safari private window throws out of a page load
class CelebrationRelayJsTest < ActiveSupport::TestCase
  PARTIAL = Rails.root.join("app/views/shared/_celebration_relay.html.erb")

  # The relay script, lifted verbatim. The partial carries no ERB output tag
  # inside its script on purpose, so the raw file IS what a browser receives.
  def relay_source
    src = File.read(PARTIAL)
    open_at  = src.index("<script>")
    close_at = src.index("</script>")
    assert open_at, "the relay partial rendered no script tag"
    assert close_at && close_at > open_at, "could not bound the relay script"
    src[(open_at + "<script>".length)...close_at]
  end

  # storage: :ok      a working store
  #          :throws  every access raises, as it does in a Safari private window
  #          :absent  the property itself raises on read
  # prefill: a raw string written to the relay's key BEFORE the script runs, so a
  #          corrupt or stale record can be presented exactly as a device would.
  def run_js(body, storage: :ok, prefill: nil, prefill_key: "tm_celebration_relay")
    store_js =
      case storage
      when :throws
        <<~JS
          window.localStorage = {
            getItem: function () { throw new Error('SecurityError'); },
            setItem: function () { throw new Error('QuotaExceededError'); },
            removeItem: function () { throw new Error('SecurityError'); }
          };
        JS
      when :absent
        # A getter that raises is how an embedded webview refuses the store —
        # reading window.localStorage is itself the throw, before any method.
        <<~JS
          Object.defineProperty(window, 'localStorage', {
            get: function () { throw new Error('SecurityError'); }
          });
        JS
      else
        <<~JS
          var _mem = {};
          window.localStorage = {
            getItem: function (k) { return Object.prototype.hasOwnProperty.call(_mem, k) ? _mem[k] : null; },
            setItem: function (k, v) { _mem[k] = String(v); },
            removeItem: function (k) { delete _mem[k]; }
          };
          window.__raw = function (k) { return window.localStorage.getItem(k); };
        JS
      end

    prefill_js =
      if prefill
        "window.localStorage.setItem(#{prefill_key.to_json}, #{prefill.to_json});"
      else
        ""
      end

    full = <<~JS
      global.window = global;
      // The relay schedules its drain off document events. A bare shim is enough:
      // with no Alpine present the schedule parks on a listener that never fires,
      // so the auto-drain cannot race the assertions below.
      window.document = {
        readyState: 'complete',
        addEventListener: function () {}
      };
      console.warn = function () {};
      #{store_js}
      #{prefill_js}
      #{relay_source}
      var RESULT;
      try { RESULT = { ok: true, value: (function () { #{body} })() }; }
      catch (e) { RESULT = { ok: false, message: e.message }; }
      process.stdout.write(JSON.stringify(RESULT));
    JS

    stdout, stderr, status = Open3.capture3("node", "--eval", full)
    assert status.success?, "node failed: #{stderr}"
    JSON.parse(stdout)
  end

  # --- the codec -----------------------------------------------------------

  test "a stashed payload reads back under its own kind" do
    result = run_js(<<~JS)
      var R = window.tmCelebrationRelay;
      R.stash('contest_entry', { tx_signature: 'SIG-1', seeds_total: 40 });
      return R.peek('contest_entry');
    JS

    assert result["ok"], result["message"]
    assert_equal({ "tx_signature" => "SIG-1", "seeds_total" => 40 }, result["value"],
                 "the payload the landing page paints from must survive the write verbatim")
  end

  test "stash answers whether the payload was actually persisted" do
    # A caller that cares can say "no party on this device" instead of promising
    # one the store cannot deliver.
    written = run_js("return window.tmCelebrationRelay.stash('contest_entry', { tx_signature: 'S' });")
    assert_equal true, written["value"]

    refused = run_js("return window.tmCelebrationRelay.stash('contest_entry', { tx_signature: 'S' });",
                     storage: :throws)
    assert_equal false, refused["value"],
                 "a store that refuses the write must be reported, not assumed to have taken it"
  end

  test "take is single-use" do
    # THE PROPERTY: a reload, a back button, or a listener that fires twice finds
    # an empty slot. Without it the second page load throws the same party again.
    result = run_js(<<~JS)
      var R = window.tmCelebrationRelay;
      R.stash('contest_entry', { tx_signature: 'SIG-2' });
      return { first: R.take('contest_entry'), second: R.take('contest_entry') };
    JS

    assert result["ok"], result["message"]
    assert_equal({ "tx_signature" => "SIG-2" }, result["value"]["first"])
    assert_nil result["value"]["second"],
               "the slot must be spent by the read that consumed it"
  end

  test "a record older than the relay's own bound reads as absent and is cleared" do
    # Written with a stashedAt the relay itself would reject. Reaching past the
    # public surface for MAX_AGE_MS keeps this honest if the bound is retuned.
    result = run_js(<<~JS)
      var R = window.tmCelebrationRelay;
      var stale = JSON.stringify({
        kind: 'contest_entry',
        payload: { tx_signature: 'YESTERDAY' },
        stashedAt: Date.now() - (R.MAX_AGE_MS + 1000)
      });
      window.localStorage.setItem(R.KEY, stale);
      var read = R.peek('contest_entry');
      return { read: read, leftBehind: window.__raw(R.KEY) };
    JS

    assert result["ok"], result["message"]
    assert_nil result["value"]["read"],
               "an expired celebration must not be painted"
    assert_nil result["value"]["leftBehind"],
               "expiry is an answer, not a decision to re-make on every future read"
  end

  test "a record still inside the bound is painted" do
    # The other half of the expiry test. Without it, a relay that cleared
    # EVERYTHING would pass the test above and celebrate nothing, ever.
    result = run_js(<<~JS)
      var R = window.tmCelebrationRelay;
      window.localStorage.setItem(R.KEY, JSON.stringify({
        kind: 'contest_entry',
        payload: { tx_signature: 'FRESH' },
        stashedAt: Date.now() - (R.MAX_AGE_MS - 1000)
      }));
      return R.peek('contest_entry');
    JS

    assert_equal({ "tx_signature" => "FRESH" }, result["value"])
  end

  test "one flow cannot read another flow's payload, and does not destroy it" do
    # THE KIND IS WHAT MAKES THIS A PRIMITIVE rather than a contest-entry
    # one-off. A rename landing page asking for its own celebration must get
    # nothing — and must leave the entry's payload for the page that can paint it.
    result = run_js(<<~JS)
      var R = window.tmCelebrationRelay;
      R.stash('contest_entry', { tx_signature: 'SIG-3' });
      var wrong = R.take('username_rename');
      return { wrong: wrong, stillThere: R.peek('contest_entry') };
    JS

    assert result["ok"], result["message"]
    assert_nil result["value"]["wrong"]
    assert_equal({ "tx_signature" => "SIG-3" }, result["value"]["stillThere"],
                 "a payload belongs to the flow that stashed it")
  end

  test "a corrupt record is discarded rather than left to fail every future read" do
    result = run_js("return { read: window.tmCelebrationRelay.peek('contest_entry'), " \
                    "leftBehind: window.__raw(window.tmCelebrationRelay.KEY) };",
                    prefill: "{not json at all")

    assert result["ok"], result["message"]
    assert_nil result["value"]["read"]
    assert_nil result["value"]["leftBehind"]
  end

  test "a store that refuses every access degrades to nothing pending" do
    # Safari private windows and some embedded webviews throw outright, and those
    # are exactly the browsers a mobile wallet flow runs in. An exception thrown
    # out of a page load would cost the whole document, not just the party.
    result = run_js(<<~JS, storage: :absent)
      var R = window.tmCelebrationRelay;
      return { stashed: R.stash('contest_entry', { tx_signature: 'S' }), read: R.peek('contest_entry') };
    JS

    assert result["ok"], "reading a refused store must not throw: #{result['message']}"
    assert_equal false, result["value"]["stashed"]
    assert_nil result["value"]["read"]
  end

  # --- the drain -----------------------------------------------------------

  test "drain hands the payload to the painter registered for that kind" do
    result = run_js(<<~JS)
      var R = window.tmCelebrationRelay;
      var painted = [];
      R.define('contest_entry', function (p) { painted.push(p); });
      R.stash('contest_entry', { tx_signature: 'SIG-4' });
      var kind = R.drain();
      return { kind: kind, painted: painted };
    JS

    assert result["ok"], result["message"]
    assert_equal "contest_entry", result["value"]["kind"]
    assert_equal [{ "tx_signature" => "SIG-4" }], result["value"]["painted"],
                 "the painter must receive the payload the flow stashed"
  end

  test "drain paints once even when called again" do
    result = run_js(<<~JS)
      var R = window.tmCelebrationRelay;
      var painted = 0;
      R.define('contest_entry', function () { painted++; });
      R.stash('contest_entry', { tx_signature: 'SIG-5' });
      R.drain();
      R.drain();
      R.drain();
      return painted;
    JS

    assert_equal 1, result["value"],
                 "the landing page may drain on load AND on a turbo visit; the slot is spent once"
  end

  test "a painter that throws costs one celebration, not every page load" do
    # TAKE BEFORE PAINT is what buys this. Painting first and clearing after
    # would leave a broken painter re-firing on every document for ten minutes.
    result = run_js(<<~JS)
      var R = window.tmCelebrationRelay;
      var attempts = 0;
      R.define('contest_entry', function () { attempts++; throw new Error('painter is broken'); });
      R.stash('contest_entry', { tx_signature: 'SIG-6' });
      R.drain();
      R.drain();
      return { attempts: attempts, leftBehind: window.__raw(R.KEY) };
    JS

    assert result["ok"], "a throwing painter must not throw out of drain: #{result['message']}"
    assert_equal 1, result["value"]["attempts"]
    assert_nil result["value"]["leftBehind"]
  end

  test "a kind with no painter on this document is left for a document that has one" do
    # The painter ships in a partial the layout renders, so its absence means
    # this page genuinely cannot paint that kind — not that the payload is spent.
    result = run_js(<<~JS)
      var R = window.tmCelebrationRelay;
      R.stash('username_rename', { name: 'newname' });
      var kind = R.drain();
      return { kind: kind, stillThere: R.peek('username_rename') };
    JS

    assert result["ok"], result["message"]
    assert_nil result["value"]["kind"]
    assert_equal({ "name" => "newname" }, result["value"]["stillThere"])
  end

  test "drain on a document with nothing waiting is a no-op" do
    # EVERY page in this app is this case. The relay renders on all of them.
    result = run_js(<<~JS)
      var R = window.tmCelebrationRelay;
      var painted = 0;
      R.define('contest_entry', function () { painted++; });
      return { kind: R.drain(), painted: painted };
    JS

    assert result["ok"], result["message"]
    assert_nil result["value"]["kind"]
    assert_equal 0, result["value"]["painted"]
  end
end
