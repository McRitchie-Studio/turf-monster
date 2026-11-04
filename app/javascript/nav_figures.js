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
// ONE PERSON, ONE WALLET, ONE CLUSTER. A record carries the user, the address and the cluster the
// body was rendered for, and a record for anyone else is deleted unread. Act as changes the user,
// so it changes the key. Logout clears sessionStorage (session_wipe.js).
//
// CLASSIC AND SYNCHRONOUS ON PURPOSE. The layout loads it by src straight after the navbar, so
// the parser paints the figures before the first frame can show the navbar without them. A module
// is deferred, so it can be too late. It is a named file so it adds no inline script, and 'self'
// and the request's nonce both cover it under the strict policy.
(function () {
  var KEY = "tm:nav-figures";
  // A spend is settling (solana_utils.js): the pre-spend figure must not come back.
  var SETTLE_KEY = "tm:onchain-settle-until";

  function who(body) {
    var data = body && body.dataset;
    if (!data || !data.userId || !data.walletAddress) return null;
    return [data.userId, data.walletAddress, data.solanaCluster || ""].join("|");
  }

  function forget() {
    try { window.sessionStorage.removeItem(KEY); } catch (_error) { /* nothing was kept */ }
  }

  function read(body) {
    var record = null;
    try { record = JSON.parse(window.sessionStorage.getItem(KEY) || "null"); } catch (_error) { record = null; }
    if (!record) return null;
    if (record.who !== who(body)) {
      forget();
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

  function settling() {
    try { return !!window.sessionStorage.getItem(SETTLE_KEY); } catch (_error) { return false; }
  }

  function paintAmount(root, record) {
    if (!record.amount) return;
    root.querySelectorAll("[data-balance-display]").forEach(function (el) {
      if (el.textContent.trim() !== "") return; // A warm render knows better.
      var free = record.tokens > 0 && record.amount === "$0";
      el.textContent = record.amount;
      el.classList.toggle("hidden", free);
      var slot = el.closest("[data-balance-slot]");
      var label = slot && slot.querySelector("[data-free-entry-label]");
      if (label) label.classList.toggle("is-active", free);
    });
  }

  function paintTokens(root, record) {
    if (!(record.tokens > 0)) return;
    root.querySelectorAll("[data-free-entry-badge]").forEach(function (el) { el.classList.remove("hidden"); });
  }

  function paintSeeds(root, record) {
    if (record.seeds === undefined || record.level === undefined) return;
    root.querySelectorAll("[data-nav-seeds-row] [data-initial-seeds-total]").forEach(function (bar) {
      if ((parseInt(bar.dataset.initialSeedsTotal, 10) || 0) >= record.seeds) return;
      bar.dataset.initialSeedsTotal = record.seeds;
      bar.dataset.initialLevel = record.level;
      bar.dataset.initialToward = record.toward;
      var fill = bar.querySelector(".seeds-bar-continuous");
      if (fill) fill.style.setProperty("--bar-progress", record.toward);
      bar.querySelectorAll("[data-seeds-level]").forEach(function (el) { el.textContent = "Level " + record.level; });
      bar.querySelectorAll("[data-seeds-text-fill]").forEach(function (el) {
        el.style.clipPath = "inset(0 " + (100 - record.toward) + "% 0 0)";
      });
    });
  }

  // root is the document on a full load and the incoming body on a Turbo visit.
  function paint(root, body) {
    var record = read(body);
    if (!record || settling()) return false;
    paintAmount(root, record);
    paintTokens(root, record);
    paintSeeds(root, record);
    return true;
  }

  function known() {
    var record = read(document.body);
    return !!(record && record.amount);
  }

  if (window.TurfNavFigures) {
    // Turbo ran this tag again after a swap: the listener below already painted that body.
    return;
  }
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

  paint(document, document.body);
})();
