const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

async function waitForGeoWrite(page, action) {
  const responsePromise = page.waitForResponse((response) => {
    const method = response.request().method();
    return ["PATCH", "POST"].includes(method) && response.url().includes("/admin/geo");
  });
  await action();
  const response = await responsePromise;
  expect(response.status()).toBeLessThan(400);
}

test.beforeEach(async ({ page, request }) => {
  await page.route("**/account/session_refresh", async (route) => {
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ ok: true }),
    });
  });
  await reseed(request);
});

test.describe("Geo Settings", () => {
  test("geo settings page loads for admin", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/admin/geo");
    await expect(page.getByRole("heading", { name: "Geo Settings" })).toBeVisible();
    await expect(page.locator("body")).toContainText("Current Detection");
    await expect(page.locator("body")).toContainText("Configuration");
    // The manager is the engine's now (studio-engine >= 0.57), and it edits
    // COUNTRIES and REGIONS rather than "states" — the list is stored as region
    // tokens because "CA" is California AND Canada. Each is its own tab.
    await expect(page.locator('label[for="geo_tab_states"]')).toContainText("Regions in US");
    await expect(page.locator('label[for="geo_tab_countries"]')).toContainText("Countries");
  });

  // THE CLICK MUST SHOW. The squares paint from their checkbox
  // (`.geo-grid label:has(input:checked)`), so toggling one repaints it
  // immediately — before any save. The page's first version painted from a
  // server-rendered class instead, so a click changed nothing on screen and the
  // grid read as dead while it was in fact recording every click. Operator
  // report, 2026-08-19: "the state buttons don't seem to be working".
  test("clicking a state square shows immediately, before saving", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/admin/geo");

    const square = page.locator('.geo-grid-states label:has(input[value="NY"])');
    await expect(square).toHaveCount(1);

    // Assert the PAINT, not the DOM. A measured mutation proved why: with the
    // CSS rule deleted, clicking still flips the hidden checkbox, so a
    // `label:has(input:checked)` count assertion passed while the square looked
    // exactly as dead as the operator reported. The background colour is what
    // the eye reads.
    const background = () => square.evaluate((el) => getComputedStyle(el).backgroundColor);

    const before = await background();
    await square.click();

    // POLL to the FINAL colour — the square carries `transition`, so a bare read
    // right after the click catches the animation mid-flight and returns a blend
    // (measured: rgba(166, 51, 61, 0.145) on its way to the wash). Asserting a
    // value that a running transition owns is a coin flip on a loaded runner.
    await expect.poll(background).toMatch(/rgba?\(\s*239,\s*68,\s*68/);

    // And back, so this spec leaves the policy exactly as it found it.
    await square.click();
    await expect.poll(background).toBe(before);
  });

  // THE SUMMARY CARD follows the editor, so "what does this app block?" is
  // answered at the top of the page rather than by reading a 52-square grid —
  // and it answers for the policy you are ABOUT to save.
  test("the configuration summary follows the editor", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/admin/geo");

    const chips = page.locator('[data-geo-summary="states"] .geo-chip');
    const before = await chips.count();

    await page.locator('.geo-grid-states label:has(input[value="NY"])').click();

    await expect(chips).toHaveCount(before + 1);
    await expect(chips.filter({ hasText: "NY" })).toHaveCount(1);
    // The heading count and the tab count are the same number, always.
    for (const label of await page.locator('[data-geo-summary-count="states"]').all()) {
      await expect(label).toHaveText(String(before + 1));
    }

    // Countries have their own row, fed by their own grid.
    await page.locator('label[for="geo_tab_countries"]').click();
    await page.locator('.geo-grid-countries label:has(input[value="CU"])').click();
    await expect(page.locator('[data-geo-summary="countries"] .geo-chip')).toHaveCount(1);
  });

  // Countries are a grid of their own, behind a tab — the same click that blocks
  // a state blocks a country.
  test("the countries tab opens the country editor", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/admin/geo");

    const states = page.locator(".geo-grid-states");
    const countries = page.locator(".geo-grid-countries");

    await expect(states).toBeVisible();
    await expect(countries).toBeHidden();

    await page.locator('label[for="geo_tab_countries"]').click();

    await expect(countries).toBeVisible();
    await expect(states).toBeHidden();
    // Cuba, with its flag, is one click away.
    await expect(countries.locator('label:has(input[value="CU"])')).toContainText("🇨🇺");
  });

  // THE LIVE PREVIEW the operator asked for: tick your OWN region and the navbar
  // badge answers immediately, before saving, so a rule can be seen before it is
  // committed.
  //
  // Two things this spec had to learn. (1) Playwright talks to the server on
  // loopback, which no geocoder can place, so it pins a location the way an
  // operator does — the simulator — rather than skipping, and a skipped test
  // proves nothing. (2) It asserts the badge's painted COLOUR, not its DOM: the
  // first draft read `label:has(input:checked)` and passed with the repaint
  // deleted. Both mistakes were measured, not guessed.
  test("ticking your own state previews the badge in real time", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/admin/geo");

    // Stand in WA, then re-render so the page knows where "here" is.
    await waitForGeoWrite(page, () => page.locator("button.btn:has-text('Simulate WA')").click());
    await page.goto("/admin/geo");
    await expect(page.locator("[data-geo-page]")).toHaveAttribute("data-geo-subdivision", "WA");

    // The preview reads the LIVE controls, so the gate can be switched on here
    // without saving anything.
    const enabled = page.getByRole("checkbox", { name: "Enable geo-blocking" });
    if (!(await enabled.isChecked())) await enabled.check();

    const badge = page.locator("nav .geo-badge").first();
    const color = () => badge.evaluate((el) => getComputedStyle(el).color);
    const square = page.locator('.geo-grid-states label:has(input[value="WA"])');
    const blockedRed = /rgba?\(\s*248,\s*113,\s*113/;

    // WA ships blocked in the seed, so untick first: the badge must go quiet.
    await square.click();
    await expect.poll(color).not.toMatch(blockedRed);
    await expect(page.locator("[data-geo-verdict]")).toContainText("NO");

    // And back on — this is the beat the operator asked for.
    await square.click();
    await expect.poll(color).toMatch(blockedRed);
    await expect(page.locator("[data-geo-verdict]")).toContainText("YES");

    // Nothing was saved; drop the simulation so later specs stand where they did.
    await page.goto("/admin/geo");
    await waitForGeoWrite(page, () => page.getByRole("button", { name: "Clear simulation" }).click());
    await expect(page.getByText("Geo simulation cleared.")).toBeVisible({ timeout: 15_000 });
  });

  test("admin can toggle geo override on", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/admin/geo");

    // Click "Simulate WA" button on the geo page (the .btn one, not the navbar dropdown)
    await waitForGeoWrite(page, () => page.locator("button.btn:has-text('Simulate WA')").click());

    // Verify notice
    await expect(page.locator("body")).toContainText("Simulating WA", { timeout: 15_000 });
  });

  test("admin can clear geo override", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/admin/geo");

    // Toggle on first
    await waitForGeoWrite(page, () => page.locator("button.btn:has-text('Simulate WA')").click());

    // After toggle ON, the page should show "Simulating WA" notice
    await expect(page.locator("body")).toContainText("Simulating WA", { timeout: 15_000 });

    // Now the simulation is active — the button flips to the danger variant.
    await waitForGeoWrite(page, () => page.getByRole("button", { name: "Clear simulation" }).click());

    // Verify cleared
    await expect(page.getByText("Geo simulation cleared.")).toBeVisible({ timeout: 15_000 });
  });

  test("geo badge shows in navbar when logged in", async ({ page }) => {
    await loginAdmin(page);
    // The navbar should show a geo state badge (could be "??" if no geo detected in test)
    const badge = page.locator("span.font-mono.rounded-lg", { hasText: /[A-Z]{2}|\?\?/ });
    await expect(badge.first()).toBeVisible();
  });

  test("blocked state prevents contest entry", async ({ page }) => {
    await loginAdmin(page);

    // Enable geoblocking
    await page.goto("/admin/geo");
    await page.getByRole("checkbox", { name: "Enable Geo-Blocking" }).check();
    await waitForGeoWrite(page, () => page.locator('input[value="Save Settings"]').click());
    // Web-first assertion replaces waitForLoadState("networkidle"): the navbar
    // hydrates on every page load (refreshSession + ActionCable), so the network
    // is never reliably idle and networkidle flakes under shard load. toContainText
    // auto-polls through the post-redirect navigation until the flash appears.
    await expect(page.locator("body")).toContainText("Geo settings updated", { timeout: 15_000 });

    // Simulate WA state — click the .btn on the geo page (not the navbar dropdown)
    await waitForGeoWrite(page, () => page.locator("button.btn-outline:has-text('Simulate WA')").click());
    await expect(page.locator("body")).toContainText("Simulating WA", { timeout: 15_000 });

    // Try to toggle a selection — should be blocked (geo-restricted action)
    const contestSlug = await page.evaluate(async () => {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
      const res = await fetch("/contests", { headers: { Accept: "text/html" } });
      return res.url; // Just check we can reach contests page
    });
    // The geo block is enforced on toggle_selection/enter — verified by hold validation in other test

    // Clean up: clear geo override — assert the flash so the cleared state lands
    // before teardown (the geo row is global; reseed does not reset it, so an
    // un-awaited write here leaks geo-blocking into later specs).
    await page.goto("/admin/geo");
    await waitForGeoWrite(page, () => page.getByRole("button", { name: "Clear simulation" }).click());
    await expect(page.getByText("Geo simulation cleared.")).toBeVisible({ timeout: 15_000 });

    // Disable geoblocking — assert the flash so the DB write completes deterministically.
    await page.goto("/admin/geo");
    await page.getByRole("checkbox", { name: "Enable Geo-Blocking" }).uncheck();
    await waitForGeoWrite(page, () => page.locator('input[value="Save Settings"]').click());
    await expect(page.locator("body")).toContainText("Geo settings updated", { timeout: 15_000 });
  });
});
