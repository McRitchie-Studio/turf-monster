const { test, expect } = require("@playwright/test");
const { login, reseed } = require("./helpers");

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
    const rename = page.locator("button[data-frozen-cta]", { hasText: "Change username" });
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
});
