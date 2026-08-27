const { test, expect } = require("@playwright/test");

// [e2e] The debug logger's default, as a REAL browser computes it.
//
// WHY THIS IS NOT A MARKUP TEST. window.DEBUG_NET is runtime state: the module
// reads document.body.dataset.appEnvironment at parse time and decides. The
// server's bytes are identical either way — the same script tag, the same body
// attribute — and every String assertion passes whether the logger armed itself
// or not. Only a browser that actually ran the module can say.
//
// What it defends: the logger printed the /auth/solana/verify request body, which
// carries the SIWS message and the FULL base58 signature, plus session_state's
// fresh CSRF token on the response side. It defaulted ON everywhere and shipped to
// production, so any open console read live credentials.
test.describe("debug logger default", () => {
  test("does NOT arm itself outside development", async ({ page }) => {
    await page.goto("/", { waitUntil: "domcontentloaded" });

    // Precondition: if the lane ever runs as development this proves nothing, so
    // assert the environment rather than assuming it.
    const env = await page.evaluate(() => document.body?.dataset?.appEnvironment);
    expect(["development", "qa"], `lane env is ${env}; this spec needs a non-dev env`)
      .not.toContain(env);

    const armed = await page.evaluate(() => window.DEBUG_NET);
    expect(armed, "a traffic logger that arms itself here would print live " +
                  "signatures and CSRF tokens to any console that happens to be open")
      .toBe(false);
  });

  test("an explicit opt-in still wins — the DevTools escape hatch survives", async ({ page }) => {
    await page.addInitScript(() => { window.DEBUG_NET = true; });
    await page.goto("/", { waitUntil: "domcontentloaded" });

    expect(await page.evaluate(() => window.DEBUG_NET),
      "someone who can already read the console must still be able to turn it on")
      .toBe(true);
  });
});
