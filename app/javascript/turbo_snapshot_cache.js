// Let Turbo finish filing its snapshot BEFORE the page swap that starves it.
//
// THE ORDERING BUG, read out of turbo.js (turbo-rails 2.0.23):
//
//   async cacheSnapshot(snapshot = this.snapshot) {   // wraps the LIVE document
//     this.delegate.viewWillCacheSnapshot()           // -> turbo:before-cache
//     const { lastRenderedLocation: location } = this
//     await nextEventLoopTick()                       // setTimeout(..., 0)
//     const cachedSnapshot = snapshot.clone()         // deep-clones the document
//     this.snapshotCache.put(location, cachedSnapshot)
//   }
//
// The clone and the put are deferred by one macrotask. The body swap that follows
// is scheduled separately, on requestAnimationFrame (`nextRepaint()`). Nothing
// orders the two, and the swap is not cheap on a big page.
//
// MEASURED on /contests/world-cup-2026 (a ~300KB-of-text page), reduced motion:
//
//   turbo:before-cache@1815 -> turbo:render@1826 -> BACK visit@1841 -> before-cache@1898
//
// The frame won, the render occupied the main thread, and the clone had still not
// been filed when Back was pressed 15ms later. Turbo found no cached snapshot for
// the outgoing URL, so `shouldIssueRequest()` sent the restoration visit to the
// NETWORK (the 57ms gap above is that round trip) and rendered a fresh server page.
// The correct snapshot lands in the cache moments later, too late to be used.
//
// The same unordered tick has a second failure mode: when the clone runs after the
// swap it clones the INCOMING page and files it under the OUTGOING page's URL, and
// Back then renders the page you just left. One fix covers both.
//
// WHY IT WAS INVISIBLE UNTIL NOW: Turbo turns view transitions OFF under reduced
// motion -- `get prefersViewTransitions()` ends in
// `&& !window.matchMedia("(prefers-reduced-motion: reduce)").matches` (turbo.js:2661).
// With them ON, the swap runs inside document.startViewTransition, whose ~30ms of
// setup (measured: before-cache@1829 -> DOM write@1861) let the timer fire first
// every time. So this is gated on an ACCESSIBILITY SETTING, not on animation: a
// reduced-motion visitor got a broken Back on any journey whose state lives only in
// the DOM. The engine's reduced-motion rule over ::view-transition-* is NOT involved
// -- Turbo never starts a transition for that CSS to strip.
//
// WHO IT HURTS: a signed-out visitor. Guest picks never reach the server
// (toggleSelection returns early on !loggedIn), so the snapshot is the only copy of
// them. A signed-in user's cart is persisted, so the server render repairs the same
// journey and it looks fine -- which is why the signed-in twin passed throughout.
//
// THE FIX: hold the page swap for one macrotask. turbo:before-cache always precedes
// turbo:before-render within a visit, so Turbo's clone timer is queued first and
// FIFO ordering of equal-delay macrotasks puts it ahead of ours. The snapshot is
// filed before the swap begins, with no dependence on how long a frame takes. When
// the clone has already been filed this costs one tick and nothing else.
//
// Deliberately NOT fixed with `turbo-cache-control: no-cache`: that strands the
// guest completely -- no snapshot to restore from, and nothing on the server either.
//
// Covered by e2e/cart_survives_turbo_restore.spec.js (Back and Forward, under the
// lane's real reduced-motion default) and test/lib/turbo_snapshot_cache_wiring_test.rb.

let cloneAwaitingTick = false;

document.addEventListener("turbo:before-cache", () => {
  cloneAwaitingTick = true;
});

// A visit can cache and then never render (aborted, redirected away). Drop the flag
// so the next render is not held on behalf of a clone that already landed.
document.addEventListener("turbo:load", () => {
  cloneAwaitingTick = false;
});

document.addEventListener("turbo:before-render", (event) => {
  if (!cloneAwaitingTick) return;
  cloneAwaitingTick = false;

  // resume() exists only for renderers that honor preventDefault. Never swallow a
  // render we have no way to restart.
  const resume = event.detail && event.detail.resume;
  if (typeof resume !== "function") return;

  event.preventDefault();
  setTimeout(resume, 0);
});
