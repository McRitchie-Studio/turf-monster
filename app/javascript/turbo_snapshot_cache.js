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
// THERE IS A SECOND FAILURE MODE, AND THE HOLD BELOW DOES NOT COVER IT. An earlier
// version of this comment claimed "one fix covers both". That was wrong, and the
// measurement is written out here so the next reader does not have to rediscover it.
//
// The outgoing DOM can be filed under the WRONG URL, clobbering a good snapshot.
// The cause is not the unordered tick above -- it is where Turbo reads the key from
// (turbo.js 2.0.23):
//
//   viewRenderedSnapshot(_snapshot, _isPreview, renderMethod) {
//     this.view.lastRenderedLocation = this.history.location;   // :4427
//     ...
//   async cacheSnapshot(snapshot = this.snapshot) {             // :4089
//     const { lastRenderedLocation: location } = this           // :4090  <- the KEY
//
// lastRenderedLocation is stamped from history.location read at render COMPLETION,
// not from the visit that authorized the render. So a history traversal that lands
// INSIDE a render retargets the stamp, and the next cacheSnapshot() files the
// outgoing DOM under that wrong key. MEASURED, Forward-then-Back (ms from load):
//
//   1728 before-render -> /turf-totals-v1   (body still the contest page)
//   1730 cache.put     -> key=/contests     GOOD: the cart snapshot is filed
//   1732 goBack        -> history.location becomes /contests, MID-RENDER
//   1737 render done   -> stamped /contests, though it rendered the RULES page
//   1752 cache.put     -> key=/contests     the cart snapshot is CLOBBERED
//
// Back then served the Rules page under the contest URL for seconds.
//
// WHY IT IS NOT FIXED HERE. It needs a second visit to start while the first is
// still rendering, which the hold below lengthens the window for. Both candidate
// fixes were built and measured and both were REJECTED:
//
//   1. Re-stamping view.lastRenderedLocation after a held render. It does correct
//      the filing (verified: the Rules dom goes back to the Rules key, and Forward
//      becomes a cache HIT instead of a network refetch). But with two visits in
//      flight the RENDERS still land out of order, so the page settles on the wrong
//      one about half the time. Ordering the held renders too did not close it.
//   2. turbo-cache-control: no-cache on the suspect write -- see the note at the
//      bottom of this comment for why that answer strands the guest.
//
// So this is a Turbo visit-lifecycle hazard, not something a page-level module can
// close honestly, and shipping half of a concurrency fix is worse than shipping
// none. It is filed rather than fixed. What it needs from a caller is ordinary:
// let a navigation FINISH before starting the next one. e2e/cart_survives_turbo_restore.spec.js
// does exactly that (it waits for turbo:load, not merely the URL flip) and says so.
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
