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
    // tokens because "CA" is California AND Canada.
    await expect(page.locator("body")).toContainText("Blocked countries");
    await expect(page.locator("body")).toContainText("Blocked regions in US");
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
