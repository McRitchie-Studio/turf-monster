// Entry-token badge — navbar ✨ badge + click-to-show count popover.
// Used by components/_entry_token_badge.html.erb. Replaces the inline
// x-data that read dataset.tokenCount on every toggle (passive sync from
// updateNavTokens in solana_utils.js); this factory subscribes to a
// window 'entry-tokens-updated' event so the reactive count stays live
// without dataset polling. The dataset attr is still maintained as a
// fallback for any code paths not migrated yet.
//
// opts:
//   initialCount: server-rendered token count at page load

function entryTokenBadge(opts) {
  opts = opts || {};
  return {
    open: false,
    count: parseInt(opts.initialCount, 10) || 0,
    _timer: null,
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
      clearTimeout(this._timer);
    },

    toggle() {
      this.open = !this.open;
      clearTimeout(this._timer);
      if (this.open) {
        var self = this;
        this._timer = setTimeout(function () { self.open = false; }, 2000);
      }
    },

    close() {
      this.open = false;
      clearTimeout(this._timer);
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
