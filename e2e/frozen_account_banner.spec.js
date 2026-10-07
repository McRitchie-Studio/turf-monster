const { test, expect } = require("@playwright/test");
const { login, loginAdmin, reseed } = require("./helpers");

// The account freeze as a frozen player sees it (turf-frozen-accounts-block-
// actions, OPSEC-048). The integration tier proves the banner is in the HTML;
// only a browser proves it is VISIBLE on the painted page (not clipped under
// the fixed navbar or hidden by a cloak) and that the disabled call to action
// really cannot be pressed.
//
// The freeze is set through TestController#set_frozen, which runs User#freeze!
// like an operator would. reseed does not reset rows between specs, so every
// path out of this file thaws the account again (afterEach).
const PLAYER = "mason@mcritchie.studio";

test.describe("Frozen account", () => {
  test.beforeEach(async ({ request }) => await reseed(request));

  test.afterEach(async ({ page }) => {
    await page.request.post("/test/set_frozen", { data: { frozen: "false" } });
  });

  test("a frozen player sees the banner on every page and a disabled rename", async ({ page }) => {
    await login(page, PLAYER);

    // Control: in good standing there is no banner.
    await page.goto("/contests");
    await expect(page.locator("[data-frozen-banner]")).toHaveCount(0);

    const res = await page.request.post("/test/set_frozen", { data: { frozen: "true" } });
    expect(res.ok()).toBeTruthy();
    expect((await res.json()).frozen).toBe(true);

    for (const path of ["/contests", "/contests/my", "/wallet", "/account"]) {
      await page.goto(path);
      const banner = page.locator("[data-frozen-banner]");
      await expect(banner, path).toBeVisible();
      await expect(banner, path).toContainText("Your account is frozen");
    }

    // Still on /account: the rename is offered, disabled, with the reason.
    const rename = page.locator("button[data-frozen-cta]", { hasText: "Username locked" });
    await expect(rename).toBeVisible();
    await expect(rename).toBeDisabled();
    await expect(rename).toHaveAttribute("title", "Your account is frozen");
  });

  test("the banner goes the moment the freeze is lifted", async ({ page }) => {
    await login(page, PLAYER);
    await page.request.post("/test/set_frozen", { data: { frozen: "true" } });
    await page.goto("/account");
    await expect(page.locator("[data-frozen-banner]")).toBeVisible();

    await page.request.post("/test/set_frozen", { data: { frozen: "false" } });
    await page.goto("/account");
    await expect(page.locator("[data-frozen-banner]")).toHaveCount(0);
  });

  // turf-frozen-account-followups. The funnel backgrounds are position:fixed at
  // z-index 0, so an unpositioned banner was PRESENT and toBeVisible() still
  // passed while the blobs painted over it. Only a hit test at the banner's own
  // centre proves it is on top: elementFromPoint must answer from inside it.
  test("on /tiktok the banner paints above the funnel background", async ({ browser, page }) => {
    const adminContext = await browser.newContext();
    const admin = await adminContext.newPage();
    await loginAdmin(admin);
    await admin.goto("/admin/landing_pages/tiktok/edit");
    const contestSelect = admin.locator("select[name='landing_page[contest_id]']");
    const firstContest = await contestSelect.locator("option:not([value=''])").first().getAttribute("value");
    await contestSelect.selectOption(firstContest);
    await admin.locator("input[type=checkbox][name='landing_page[active]']").check();
    await admin.getByRole("button", { name: "Save Changes" }).click();
    await admin.waitForURL((u) => !u.pathname.endsWith("/edit"));
    await adminContext.close();

    await login(page, PLAYER);
    // Control: in good standing the funnel has no banner.
    await page.goto("/tiktok");
    await expect(page).toHaveURL(/\/lp\/tiktok$/);
    await expect(page.locator("[data-frozen-banner]")).toHaveCount(0);

    await page.request.post("/test/set_frozen", { data: { frozen: "true" } });
    await page.goto("/tiktok");
    const banner = page.locator("[data-frozen-banner]");
    await expect(banner).toBeVisible();
    const onTop = await banner.evaluate((el) => {
      const r = el.getBoundingClientRect();
      const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
      return !!hit && el.closest("[data-frozen-banner-layer]").contains(hit);
    });
    expect(onTop, "the banner's centre must hit the banner, not the background").toBe(true);
  });

  test("a frozen player's pick tap toasts the freeze, not Entry Failed", async ({ page }) => {
    await login(page, PLAYER);
    await page.request.post("/test/set_frozen", { data: { frozen: "true" } });
    await page.goto("/contests/world-cup-2026");

    const tile = page.locator('[x-data*="selectionBoard"] button[role="checkbox"]:not([disabled])').first();
    await tile.click();

    await expect(page.getByText("Your account is frozen. Contact support@turfmonster.media.").first()).toBeVisible();
    await expect(page.getByText("Account frozen").first()).toBeVisible();
    await expect(page.getByText("Entry Failed")).toHaveCount(0);
    await expect(tile).toHaveAttribute("aria-checked", "false");
  });

  test("at phone width the banner is a headline and a contact, not four lines", async ({ page }) => {
    await login(page, PLAYER);
    await page.request.post("/test/set_frozen", { data: { frozen: "true" } });

    // Control: from sm up the detail clause shows.
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto("/contests");
    await expect(page.locator("[data-frozen-banner-detail]")).toBeVisible();

    await page.setViewportSize({ width: 375, height: 812 });
    await page.goto("/contests");
    const banner = page.locator("[data-frozen-banner]");
    await expect(banner).toBeVisible();
    await expect(banner).toContainText("Your account is frozen.");
    await expect(banner).toContainText("support@turfmonster.media");
    await expect(page.locator("[data-frozen-banner-detail]")).toBeHidden();
    // Measured before the change at 375px: about 100px of sticky header.
    const height = await banner.evaluate((el) => el.closest(".w-full").getBoundingClientRect().height);
    expect(height).toBeLessThanOrEqual(64);
  });
});
