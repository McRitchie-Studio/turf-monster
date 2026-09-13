require "test_helper"
require "open3"
require "json"

# [component] The relay and its first adopter, RENDERED and then RUN together.
#
# WHY THIS TIER IS NOT A DUPLICATE of the two unit tests below it. Those lift
# source out of the files by string index and drive each half alone. They
# therefore prove logic and nothing about the views: an ERB comment that swallows
# a block, a stray output tag that eats the script, a partial the layout stopped
# rendering, or two partials rendered in the wrong ORDER — each leaves both unit
# tests perfectly green while the browser receives a relay nobody registered a
# painter with.
#
# The ORDER is a real hazard here rather than a hypothetical one: the intent
# registers its painter at PARSE TIME, so a relay rendered after it would be
# handed nothing and every redirect entry would land on a page that drains a slot
# it has no painter for.
#
# So this renders both partials through the real view stack and runs WHAT CAME
# OUT, in the order the layout emits them.
class CelebrationRelayRenderingTest < ActionView::TestCase
  # Everything between the script tags a partial emits, in document order.
  def rendered_script(partial)
    html = ApplicationController.render(partial: partial)
    scripts = html.scan(%r{<script[^>]*>(.*?)</script>}m).flatten
    assert scripts.any?, "#{partial} rendered no script at all"
    scripts.join("\n")
  end

  # The two partials concatenated the way the layout emits them: relay first,
  # intent second. Anything that depends on that order fails here rather than on
  # a phone.
  def emitted_pair
    [rendered_script("shared/celebration_relay"), rendered_script("shared/contest_entry_intent")].join("\n")
  end

  def run_emitted(body)
    script = <<~JS
      global.window = global;
      var _mem = {};
      window.localStorage = {
        getItem: function (k) { return Object.prototype.hasOwnProperty.call(_mem, k) ? _mem[k] : null; },
        setItem: function (k, v) { _mem[k] = String(v); },
        removeItem: function (k) { delete _mem[k]; }
      };
      // No Alpine at load, so the relay's own scheduler parks on a listener that
      // never fires and cannot race the drain driven explicitly below.
      window.document = {
        readyState: 'complete',
        addEventListener: function () {},
        getElementById: function () { return null; }
      };
      window.location = { origin: 'https://turf.test', pathname: '/contests/12' };
      // The registry the intent registers into. Present, because on the real
      // callback document it is — the layout loads the gem script before both
      // partials.
      window.SolanaStudio = {
        walletOps: { define: function () {}, resume: function () { return Promise.resolve(); } },
        walletTransport: { base58: { encode: function (b) { return 'B58'; }, decode: function (s) { return new Uint8Array([1]); } } }
      };
      console.log = function () {};
      console.warn = function () {};
      #{emitted_pair}
      var RESULT;
      try { RESULT = { ok: true, value: (function () { #{body} })() }; }
      catch (e) { RESULT = { ok: false, message: e.message }; }
      process.stdout.write(JSON.stringify(RESULT));
    JS

    stdout, stderr, status = Open3.capture3("node", "--eval", script)
    assert status.success?, "the partials' own output failed to run in node: #{stderr}"
    JSON.parse(stdout)
  end

  test "the rendered pair carries a relay with a contest_entry painter registered" do
    result = run_emitted("return { relay: typeof window.tmCelebrationRelay, " \
                         "paint: typeof window.tmPaintEntryCelebration };")

    assert result["ok"], result["message"]
    assert_equal "object", result["value"]["relay"],
                 "the relay partial must emit a running store, not merely a file that parses"
    assert_equal "function", result["value"]["paint"]
  end

  test "a stashed entry is painted on arrival, through the rendered scripts" do
    # THE WHOLE SEAM IN ONE RUN, against real rendered output: the payload the
    # callback document wrote, drained by the landing page, painted by the
    # painter the intent registered — the three acts the redirect transport was
    # losing, reached the way a browser reaches them.
    result = run_emitted(<<~JS)
      var acts = { success: null, props: {}, fanout: null, tokens: null };
      var _visible = false;
      var solanaModal = {
        get visible() { return _visible; },
        show: function () { _visible = true; },
        success: function (tx, msg) { if (_visible) acts.success = [tx, msg]; },
        set title(v) { acts.props.title = v; },
        set lobbyUrl(v) { acts.props.lobbyUrl = v; },
        set seedsEarned(v) { acts.props.seedsEarned = v; },
        set seedsTotal(v) { acts.props.seedsTotal = v; },
        set seedsLevel(v) { acts.props.seedsLevel = v; }
      };
      var session = { tokensAvailable: 2 };
      window.Alpine = { store: function (n) { return n === 'session' ? session : solanaModal; } };
      window.StateFanout = { apply: function (t, p, o) { acts.fanout = [t, p, o]; } };

      window.tmCelebrationRelay.stash('contest_entry', {
        tx_signature: 'SIG-SEAM', redirect: '/contests/12', token_consumed: true,
        seeds_earned: 10, seeds_total: 40, seeds_level: 1
      });
      acts.drained = window.tmCelebrationRelay.drain();
      acts.sessionTokens = session.tokensAvailable;
      return acts;
    JS

    assert result["ok"], result["message"]
    acts = result["value"]

    assert_equal "contest_entry", acts["drained"],
                 "the painter the intent registered must be the one the relay finds"
    assert_equal ["SIG-SEAM", "Entry Confirmed"], acts["success"]
    assert_equal "Good Luck", acts["props"]["title"]
    assert_equal "/contests/12", acts["props"]["lobbyUrl"]
    assert_equal 1, acts["sessionTokens"], "the free-entry token this entry spent is gone"
    assert_equal 40, acts["fanout"][1]["seeds_total"]
    assert_equal "phantom-redirect", acts["fanout"][2]["source"]
  end

  test "the rendered painter carries the seeds-per-level constant, not a literal" do
    # StateFanout falls back to a HARDCODED 100 when nobody passes it, which is
    # the literal the board's pass-through exists to avoid. The relay leg lands on
    # a page that may have no board, so the constant rides the layout instead —
    # and it is an ERB output tag, so only a RENDERED run can see it.
    result = run_emitted("return window.tmSeedsPerLevel;")

    assert result["ok"], result["message"]
    assert_equal User::SEEDS_PER_LEVEL, result["value"],
                 "the painter must fan out with the model's constant"
  end

  test "the layout renders the relay, and BEFORE the partial that registers into it" do
    # PLACEMENT IS THE MECHANISM, twice over. The relay must be on the CALLBACK
    # document (which this app does not own) for the payload to be written at
    # all, which means the layout and not a page-specific view. And the intent
    # calls define() at parse time, so a relay emitted after it registers nothing.
    layout = File.read(Rails.root.join("app/views/layouts/application.html.erb"))

    relay_at  = layout.index('render "shared/celebration_relay"')
    intent_at = layout.index('render "shared/contest_entry_intent"')

    assert relay_at,
           "the relay must be rendered by the LAYOUT — the wallet returns to a page this app does not own"
    assert intent_at, "the layout no longer renders the contest entry intent"
    assert relay_at < intent_at,
           "the relay must be emitted BEFORE the intent, or there is nothing to register a painter with"
  end
end
