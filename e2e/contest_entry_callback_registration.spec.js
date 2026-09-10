// THE TEST THAT WOULD HAVE CAUGHT THE BLOCKER, and it is written to be
// impossible to satisfy the way its predecessor was.
//
// WHAT WENT WRONG BEFORE. A spec titled "the intent is registered by the name the
// callback looks up" asserted at "/" — a page that renders the contest board, and
// therefore registered the intent locally. It never visited the callback page in
// its own title. Meanwhile the integration test's freshWorld() re-injected the
// registration into its simulated callback worlds, manufacturing the very thing
// under test. Both passed over an entry that was silently lost in production.
//
// So this file visits the REAL route the wallet returns to, and asserts nothing
// about any other page.
const { test, expect } = require("@playwright/test");

// The exact route Phantom is handed as redirect_link.
const CALLBACK = "/auth/phantom/callback";

test.describe("the page a wallet actually returns to", () => {
  test("registers contest_entry on the callback route itself @smoke", async ({ page }) => {
    // No query params: the callback's own script bails early without a pending
    // journal, which is fine — registration happens at page load, before any of
    // that, and is exactly what must be present when a REAL return arrives.
    await page.goto(CALLBACK);

    await expect
      .poll(() => page.evaluate(() => typeof window.SolanaStudio?.walletOps?.defined))
      .toBe("function");

    const registered = await page.evaluate(() =>
      window.SolanaStudio.walletOps.defined("contest_entry")
    );

    expect(
      registered,
      "walletOps.resume() consumes the journal BEFORE requireHandler runs, so an " +
        "unregistered intent here loses the entry with nothing left to retry"
    ).toBe(true);
  });

  test("both handlers are callable on that page, not just named @smoke", async ({ page }) => {
    // `defined()` only proves a NAME was registered. The handlers themselves live
    // in the same partial, and a registration that pointed at undefined functions
    // would satisfy the assertion above while failing identically at run time.
    await page.goto(CALLBACK);
    await expect
      .poll(() => page.evaluate(() => typeof window.tmCompleteContestEntry))
      .toBe("function");

    const shapes = await page.evaluate(() => ({
      prepare: typeof window.tmPrepareContestEntry,
      complete: typeof window.tmCompleteContestEntry,
    }));

    expect(shapes).toEqual({ prepare: "function", complete: "function" });
  });

  test("the callback page does NOT render the contest board", async ({ page }) => {
    // THE CONTROL. Without it, both assertions above would still pass if someone
    // "fixed" this by rendering the board on the callback route — which would
    // work, and would also drag the entire board's Alpine component onto a page
    // that has no contest. If this ever goes red, the registration moved back
    // somewhere page-specific and the blocker is returning.
    await page.goto(CALLBACK);

    const hasBoard = await page.evaluate(() => !!document.getElementById("board-config"));
    expect(hasBoard, "the intent must be registered independently of the board").toBe(false);
  });
});
