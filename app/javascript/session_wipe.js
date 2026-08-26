// wipeClientState — the client half of "logout is a start-from-scratch button".
//
// Before this existed, the ONLY browser-storage clearing on logout was an inline
// onclick DUPLICATED VERBATIM in two views, removing ONE key of nineteen:
//   try{localStorage.removeItem('pendingContestEntry')}catch(e){}
// Everything else survived. `seedsNavbar`, `seedsLevelUp` and the `phantom_dl_*`
// handshake were eventually swept, but only on the NEXT page load, by the
// lastUserId identity check in the layout — a different mechanism doing
// logout's job late, and only when the next visitor differs.
//
// THIS IS AN ALLOW-LIST, NOT A DENY-LIST, and that is the whole design. The
// server side of this slice replaced two hand-maintained deny-lists that could
// not see each other and leaked seven keys between them. A `clear()` plus a
// named handful of survivors cannot leak: a key added next year by someone who
// never reads this file is wiped by default, which is the correct default for
// anything session-shaped.
//
// THE ONLY SURVIVORS ARE DEVICE PREFERENCES. `theme` and `devMode` are written
// by studio-engine (layouts/studio/_head.html.erb, studio/banners/_dev_mode_button)
// and reach every page through the layout. They describe the DEVICE, not the
// session — a user who logs out must not have the site flip from dark to light.
// Adding a third entry here means arguing that the key is a device preference
// too; if it is session state, it belongs in the wipe.
const SURVIVORS = ["theme", "devMode"];

function readSurvivors() {
  const kept = {};
  SURVIVORS.forEach((key) => {
    try {
      const value = localStorage.getItem(key);
      if (value !== null) kept[key] = value;
    } catch (e) { /* storage unavailable — nothing to keep */ }
  });
  return kept;
}

function restoreSurvivors(kept) {
  Object.keys(kept).forEach((key) => {
    try { localStorage.setItem(key, kept[key]); } catch (e) { /* best effort */ }
  });
}

// Every store is wiped INDEPENDENTLY. A private-mode browser can throw on one
// accessor and not the other, and a half-done wipe is the failure this function
// exists to prevent — so one throw must not skip the rest.
export function wipeClientState(opts) {
  opts = opts || {};
  const kept = readSurvivors();

  try { localStorage.clear(); }   catch (e) { /* private mode / quota */ }
  try { sessionStorage.clear(); } catch (e) { /* private mode / quota */ }

  restoreSurvivors(kept);

  // Sibling tabs. The channel already carries session identity broadcasts
  // (layouts/application.html.erb), and a tab that keeps a logged-in store
  // after another tab logged out is the same stale-state bug one level up.
  // `broadcast: false` stops the echo when a peer is REACTING to this message.
  if (opts.broadcast !== false) {
    try {
      const channel = new BroadcastChannel("tm-session");
      channel.postMessage({ type: "logout-wipe" });
      channel.close();
    } catch (e) { /* BroadcastChannel unsupported — same-tab wipe still happened */ }
  }

  return kept;
}

// In-memory Alpine stores are NOT re-initialised here, deliberately. Both logout
// links carry `data-turbo="false"`, so logout is a full document load and every
// store is rebuilt from its declaration by the browser — which is stronger than
// any re-init this function could write, and cannot drift as stores are added.
// The `data-turbo="false"` is therefore load-bearing, not decoration; the
// component test pins it on both links.
if (typeof window !== "undefined") {
  window.wipeClientState = wipeClientState;

  try {
    const channel = new BroadcastChannel("tm-session");
    channel.addEventListener("message", (event) => {
      if (event && event.data && event.data.type === "logout-wipe") {
        wipeClientState({ broadcast: false });
      }
    });
  } catch (e) { /* unsupported — this tab simply will not follow a peer's logout */ }
}
