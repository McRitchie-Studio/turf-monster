// The navbar's last known figures, held across a page change
// (/tasks/turf-adopts-page-transitions, docs/UI_PATTERNS.md "Page transitions").
//
// WHY THE FIGURES BLANKED. The server reads the balance from a cache only and never blocks a
// render on an RPC, so a cold render has no figure: the pill renders hidden, the seeds bar renders
// empty, and refreshSession() fills them after turbo:load. Every page change therefore flashed,
// with or without motion. Motion only made it worse, by moving turbo:load 700ms later.
//
// A DISPLAY VALUE ONLY. Nothing that signs, enters a contest or checks funds may read this. Those
// read $store.session and the server. test/lib/nav_figures_display_only_test.rb holds the readers.
//
// THE MEMORY WINS OVER THE BODY. A Turbo snapshot holds the figure from when the page was left,
// and a warm render one up to 60 seconds old. The memory holds this tab's last read, so it
// overwrites both, and the fresh read after the swap corrects it silently if it differs.
//
// ONE PERSON, ONE WALLET, ONE CLUSTER. A record carries the user, the address and the cluster the
// body was rendered for, and a record for anyone else is deleted unread. Act as changes the user,
// so it changes the key. Logout clears sessionStorage (session_wipe.js).
//
// CLASSIC, BLOCKING, IN THE HEAD, ON PURPOSE. A plain load paints as it parses, and a script tag
// after the navbar is a pause the browser can paint in: measured, one frame of an empty pill. So
// this runs ahead of the body and watches it arrive. A mutation callback runs before any frame
// can show what was inserted. A module is deferred, so it can be too late. It is a named file so
// it adds no inline script, and 'self' and the request's nonce both cover it under the strict policy.
(function () {
  var KEY = "tm:nav-figures";
  // A spend that may navigate is settling (solana_utils.js): the pre-spend figure must not come back.
  var SETTLE_KEY = "tm:onchain-settle-until";

  function who(body) {
    var data = body && body.dataset;
    if (!data || !data.userId || !data.walletAddress) return null;
    return [data.userId, data.walletAddress, data.solanaCluster || ""].join("|");
  }

  function drop() {
    try { window.sessionStorage.removeItem(KEY); } catch (_error) { /* nothing was kept */ }
  }

  function read(body) {
    var record = null;
    try { record = JSON.parse(window.sessionStorage.getItem(KEY) || "null"); } catch (_error) { record = null; }
    if (!record) return null;
    if (record.who !== who(body)) {
      drop();
      return null;
    }
    return record;
  }

  // Merges what one read learned. `asked` is who the read was made for: a read that outlives a
  // change of user must not write its answer under the new one.
  function remember(fields, asked) {
    var current = who(document.body);
    if (!current || (asked !== undefined && asked !== current)) return;
    var record = read(document.body) || { who: current };
    Object.keys(fields).forEach(function (name) {
      if (fields[name] !== undefined && fields[name] !== null) record[name] = fields[name];
    });
    try { window.sessionStorage.setItem(KEY, JSON.stringify(record)); } catch (_error) { /* display only */ }
  }

  // A spend moved the amount and maybe the tokens. Seeds only climb, so the bar keeps its figure.
  function forget() {
    var record = read(document.body);
    if (!record) return;
    delete record.amount;
    delete record.tokens;
    try { window.sessionStorage.setItem(KEY, JSON.stringify(record)); } catch (_error) { drop(); }
  }

  function settling() {
    // Two halves: the in-page window has no marker unless the caller may navigate.
    if (window.settlePending && window.settlePending()) return true;
    try { return !!window.sessionStorage.getItem(SETTLE_KEY); } catch (_error) { return false; }
  }

  function eachPill(root, paintOne) {
    root.querySelectorAll("[data-balance-display]").forEach(function (el) {
      var slot = el.closest("[data-balance-slot]");
      paintOne(el, slot && slot.querySelector("[data-free-entry-label]"));
    });
  }

  function paintAmount(root, record) {
    if (!record.amount) return;
    var free = record.tokens > 0 && record.amount === "$0";
    eachPill(root, function (el, label) {
      if (el.textContent !== record.amount) el.textContent = record.amount;
      el.classList.toggle("hidden", free);
      if (label) label.classList.toggle("is-active", free);
    });
  }

  // The hold a settling spend asks for. A snapshot must not show the pre-spend figure either.
  function blankAmount(root) {
    eachPill(root, function (el, label) {
      if (el.textContent !== "") el.textContent = "";
      el.classList.add("hidden");
      if (label) label.classList.remove("is-active");
    });
  }

  function paintTokens(root, record) {
    if (record.tokens === undefined) return;
    root.querySelectorAll("[data-free-entry-badge]").forEach(function (el) {
      el.classList.toggle("hidden", !(record.tokens > 0));
    });
  }

  function paintSeeds(root, record) {
    if (record.seeds === undefined || record.level === undefined) return;
    root.querySelectorAll("[data-nav-seeds-row] [data-initial-seeds-total]").forEach(function (bar) {
      if ((parseInt(bar.dataset.initialSeedsTotal, 10) || 0) > record.seeds) return; // Seeds only climb.
      bar.dataset.initialSeedsTotal = record.seeds;
      bar.dataset.initialLevel = record.level;
      bar.dataset.initialToward = record.toward;
      var fill = bar.querySelector(".seeds-bar-continuous");
      if (fill) fill.style.setProperty("--bar-progress", record.toward);
      bar.querySelectorAll("[data-seeds-level]").forEach(function (el) {
        var level = "Level " + record.level;
        if (el.textContent !== level) el.textContent = level;
      });
      bar.querySelectorAll("[data-seeds-text-fill]").forEach(function (el) {
        el.style.clipPath = "inset(0 " + (100 - record.toward) + "% 0 0)";
      });
    });
  }

  // root is the document on a full load and the incoming body on a Turbo visit.
  function paint(root, body) {
    var record = read(body);
    if (settling() && who(body)) {
      blankAmount(root);
      if (record) paintSeeds(root, record);
      return false;
    }
    if (!record) return false;
    paintAmount(root, record);
    paintTokens(root, record);
    paintSeeds(root, record);
    return true;
  }

  function known() {
    var record = read(document.body);
    return !!(record && record.amount);
  }

  if (window.TurfNavFigures) return;
  window.TurfNavFigures = {
    who: function () { return who(document.body); },
    remember: remember,
    forget: forget,
    known: known,
  };

  // In capture, ahead of the swap and of every picture a move takes of the new page.
  document.addEventListener("turbo:before-render", function (event) {
    var body = event.detail && event.detail.newBody;
    if (body) paint(body, body);
  }, { capture: true });

  // Each batch paints again, because the parser can add a warm render's own text after a paint.
  var watcher = new MutationObserver(function () {
    if (document.body) paint(document, document.body);
  });
  watcher.observe(document.documentElement, { childList: true, subtree: true });
  document.addEventListener("DOMContentLoaded", function () {
    watcher.disconnect();
    paint(document, document.body);
  }, { once: true });
})();
