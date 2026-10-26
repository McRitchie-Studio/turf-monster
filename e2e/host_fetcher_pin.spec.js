const { test, expect } = require("@playwright/test");

// [e2e] TURF'S REAL HOST FETCHER PIN, with nothing stood in (Carl's review note on
// engine-adoption-loose-ends: the engine's own spec stands the host pin in with
// page.route, so the real override was proven only at map draw).
//
// studio-engine pins "studio/host_fetchers" to an empty module; config/importmap.rb
// pins the same name to app/javascript/host_fetchers.js, which re-exports
// authedFetch from solana_utils. The engine's newsletter cards import that module
// on a press and call the export they name (fetcher: "authedFetch").
//
// Nothing here is routed or stubbed: the page's own importmap resolves the name,
// the module is the app's real file, and the 401 is the app's real answer to a
// signed-out JSON request (ApplicationController#require_auth). Each assertion
// fails on its own if the engine's empty pin wins: there is no export, so the
// identity check and the call both fail.
test("the studio/host_fetchers pin resolves to Turf's authedFetch, and a real 401 opens sign-in", async ({ page }) => {
  await page.goto("/contests");
  await page.waitForFunction(() => window.Alpine && Alpine.store("modals"));

  const mapped = await page.evaluate(() => {
    const map = JSON.parse(document.querySelector('script[type="importmap"]').textContent);
    return map.imports["studio/host_fetchers"];
  });
  expect(mapped, "the page's importmap maps the engine's name to this app's file").toMatch(/\/host_fetchers-[0-9a-f]+\.js$/);

  const result = await page.evaluate(async () => {
    const hosts = await import("studio/host_fetchers");
    const utils = await import("solana_utils");
    const same = typeof hosts.authedFetch === "function" && hosts.authedFetch === utils.authedFetch;
    const answer = await hosts.authedFetch("/account", { headers: { Accept: "application/json" } });
    return { exports: Object.keys(hosts), same, answered: answer === null };
  });
  expect(result.exports).toContain("authedFetch");
  expect(result.same, "the pinned export is solana_utils' own authedFetch, not a copy").toBe(true);
  expect(result.answered, "authedFetch answered the 401 itself and returned null").toBe(true);
  await expect.poll(() => page.evaluate(() => Alpine.store("modals").isOpen("auth")),
    { message: "the 401 opened the sign-in card, which plain fetch never does" }).toBe(true);
});
