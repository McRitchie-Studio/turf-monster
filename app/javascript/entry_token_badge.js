// Entry-token count — the live free-entry number.
// Used by components/_gear_sidebar.html.erb's free-entry chip. Subscribes to a
// window 'entry-tokens-updated' event (dispatched by updateNavTokens in
// solana_utils.js) so the reactive count stays live without polling the
// [data-free-entry-badge] dataset. That dataset attr is still maintained as a
// fallback for any code paths not migrated yet.
//
// It used to also drive the navbar badge's click-to-show count popover. The
// badge opens the settings sidebar now, so open/toggle/close went with the
// popover and what is left is just the count.
//
// The sidebar body renders TWICE (desktop + mobile panel), so this mounts twice
// as two independent scopes; both subscribe to the same window event, so both
// stay correct. A querySelector-based sync would have updated only one.
//
// NOTE: the LIVE copy of this factory is inline in
// app/views/shared/_alpine_factories.html.erb — importmap modules load AFTER
// Alpine processes x-data in this app. This module is the unit-testable
// duplicate and harmlessly re-assigns window.entryTokenBadge afterwards. Change
// both.
//
// opts:
//   initialCount: server-rendered token count at page load

function entryTokenBadge(opts) {
  opts = opts || {};
  return {
    count: parseInt(opts.initialCount, 10) || 0,
    _onTokensUpdated: null,

    init() {
      var self = this;
      this._onTokensUpdated = function (e) {
        var n = e && e.detail && parseInt(e.detail.count, 10);
        if (!isNaN(n)) self.count = n;
      };
      window.addEventListener("entry-tokens-updated", this._onTokensUpdated);
    },

    destroy() {
      window.removeEventListener("entry-tokens-updated", this._onTokensUpdated);
    }
  };
}

window.entryTokenBadge = entryTokenBadge;
function registerEntryTokenBadge() {
  if (typeof Alpine === "undefined") return false;
  Alpine.data("entryTokenBadge", entryTokenBadge);
  return true;
}
if (!registerEntryTokenBadge()) {
  document.addEventListener("alpine:init", registerEntryTokenBadge);
}
