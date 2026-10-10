require "open3"
require "json"

# Runs the contest board's selectionBoard() script in node, with window,
# document and Alpine stubbed at the seam, and counts what it does to them.
# Shared by the unit tier (the partial's source) and the component tier (the
# script as the contest page renders it).
module BoardScriptHarness
  # The hold button's events (studio/_hold_button), heard on document.
  HOLD_EVENTS = %w[guard start validate early success].map { |name| "document:hold-button:#{name}" }.freeze
  BOARD_EVENTS = (HOLD_EVENTS + %w[window:message window:paypal-order-captured]).freeze

  DEFAULT_CONFIG = {
    cartSelections: {}, cartSelectionOrder: [], matchupData: {}, firstMatchupIds: [],
    mode: "create", contestSlug: "the-contest", entryFeeCents: 1900, picksRequired: 6,
    contestOnchain: false, acceptsUsdt: false, seedsPerLevel: 100
  }.freeze

  # A JS object literal of the live listener count for each board event.
  def census_js
    "({ #{BOARD_EVENTS.map { |k| "#{k.to_json}: listening(#{k.to_json})" }.join(', ')} })"
  end

  # `body` runs with: newBoard() (a board Alpine has built and init()ed),
  # listening(key), fire(key), hold(name, id) (one hold-button event, returned
  # so its defaultPrevented and waited answers can be read), advance(ms) (the
  # clock: setTimeout only runs through it), enters (every /enter request),
  # fundingChecks (every pre-check request), funding (resolve the open
  # pre-check), channels (every BroadcastChannel opened).
  def run_board_js(script_source, body, config: DEFAULT_CONFIG)
    script = <<~JS
      global.window = global;
      global.console = { log: function () {}, warn: function () {}, error: function () {} };

      // Every listener, keyed 'target:event'. removeEventListener REALLY removes.
      var handlers = {};
      function listen(target) {
        return function (name, cb) { (handlers[target + ':' + name] = handlers[target + ':' + name] || []).push(cb); };
      }
      function unlisten(target) {
        return function (name, cb) {
          var list = handlers[target + ':' + name] || [];
          var i = list.indexOf(cb);
          if (i >= 0) list.splice(i, 1);
        };
      }
      global.listening = function (key) { return (handlers[key] || []).length; };
      // Copied before iterating: a handler may remove itself or its siblings.
      global.fire = function (key, event) { (handlers[key] || []).slice().forEach(function (cb) { cb(event || {}); }); };

      // One event as the engine's hold button dispatches it: detail.id is the
      // button's hold_id, and validate carries waitUntil.
      global.hold = function (name, id, target) {
        var event = {
          detail: { id: id }, target: target || { isConnected: true }, defaultPrevented: false, answers: [],
          preventDefault: function () { this.defaultPrevented = true; }
        };
        if (name === 'validate') event.detail.waitUntil = function (answer) { event.answers.push(answer); };
        fire('document:hold-button:' + name, event);
        return event;
      };

      // A clock the test moves. Nothing scheduled runs until advance() reaches it.
      var clock = 0, timers = [];
      global.setTimeout = function (fn, ms) { timers.push({ at: clock + (ms || 0), fn: fn }); return timers.length; };
      global.clearTimeout = function () {};
      global.advance = function (ms) {
        clock += ms;
        var due = timers.filter(function (t) { return t.at <= clock; });
        timers = timers.filter(function (t) { return t.at > clock; });
        due.forEach(function (t) { t.fn(); });
      };

      var cfg = #{config.to_json};
      global.document = {
        getElementById: function (id) { return id === 'board-config' ? { textContent: JSON.stringify(cfg) } : null; },
        querySelector: function () { return null; },
        querySelectorAll: function () { return []; },
        addEventListener: listen('document'),
        removeEventListener: unlisten('document')
      };
      global.addEventListener = listen('window');
      global.removeEventListener = unlisten('window');
      global.location = { search: '', origin: 'https://turf.test', href: 'https://turf.test/contests/the-contest' };
      var storage = { getItem: function () { return null; }, removeItem: function () {}, setItem: function () {} };
      global.sessionStorage = storage;
      global.localStorage = storage;

      var channels = [];
      global.BroadcastChannel = function (name) { this.name = name; this.closed = false; channels.push(this); };
      global.BroadcastChannel.prototype.close = function () { this.closed = true; };

      // A managed-wallet session that holds one entry token: the session the
      // funding pre-check runs for.
      var session = { loggedIn: true, isGuest: false, isWeb3: false, mode: 'web2', tokensAvailable: 1 };
      var modals = { stack: [], current: function () { return null; }, open: function () {}, close: function () {}, advance: function () {} };
      var solanaModal = { show: function () {}, error: function () {}, close: function () {}, success: function () {} };
      global.Alpine = { store: function (n) { return n === 'session' ? session : (n === 'modals' ? modals : solanaModal); } };
      window.eligibilityBlocker = function () { return null; };

      // The two requests a hold makes. The pre-check stays open until the test
      // resolves it; /enter never answers, so the entry stays in flight.
      var enters = [];
      var fundingChecks = [];
      var fundingResolvers = [];
      global.funding = function (answer) { fundingResolvers.splice(0).forEach(function (r) { r(answer); }); };
      window.authedFetch = function (url) {
        if (/check_funding$/.test(url)) {
          fundingChecks.push(url);
          return new Promise(function (resolve) {
            fundingResolvers.push(function (answer) { resolve({ ok: true, json: function () { return Promise.resolve(answer); } }); });
          });
        }
        if (/\\/enter$/.test(url)) { enters.push(url); return new Promise(function () {}); }
        return Promise.resolve({ ok: false, status: 404, json: function () { return Promise.resolve({}); } });
      };

      #{script_source}

      global.newBoard = function () { var b = window.selectionBoard(); b.init(); return b; };
      global.tick = function () { return new Promise(function (resolve) { setImmediate(resolve); }); };

      (async function () {
        var out;
        try {
          out = await (async function () { #{body} })();
        } catch (e) {
          out = { error: e.message, stack: String(e.stack).split("\\n").slice(0, 4) };
        }
        process.stdout.write(JSON.stringify(out));
        process.exit(0);
      })();
    JS

    stdout, stderr, status = Open3.capture3("node", "--eval", script)
    assert status.success?, "node failed: #{stderr}"
    JSON.parse(stdout)
  end
end
