const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// The navbar is studio-engine's (0.114.0; /tasks/turf-readopts-engine-navbar),
// and its content comes from the engine's slots: Studio.navbar_links and
// Studio.navbar_items render in BOTH rows of layouts/_navbar, and
// Studio.navbar_avatar_badge seats the ✨ badge over the avatar in
// components/_user_nav. test/integration/navbar_engine_slots_test.rb proves the
// engine reads each setting; this proves, in a browser at a phone and a desktop
// width, that the row a reader can SEE carries them and that Turf's controls
// still act through the engine's: the account button (Studio.navbar_account_sidebar)
// opens the gear sidebar, and Sign in (Studio.navbar_signed_out_cta modal:)
// opens the auth modal in place.

const WIDTHS = [390, 1280];
const HEADER = "header[data-navbar-root]";

async function at(page, width) {
  await page.setViewportSize({ width, height: 900 });
  await page.goto("/contests");
  await expect(page.locator(HEADER)).toBeVisible();
}

test("the declared links and items render in the row a reader sees, at 390 and 1280", async ({ page, request }) => {
  await reseed(request);
  for (const width of WIDTHS) {
    await at(page, width);
    const header = page.locator(HEADER);
    await expect(header.getByRole("link", { name: "Contests", exact: true }).filter({ visible: true })).toHaveCount(1);
    await expect(header.getByRole("link", { name: "Rules", exact: true }).filter({ visible: true })).toHaveCount(1);
    await expect(header.locator("[data-geo-badge]").filter({ visible: true })).toHaveCount(1);
    // The wallet chip hides itself while quiet (no wallet extension), but it is
    // mounted in both rows and its store has resolved a state.
    await expect(header.locator("[data-wallet-signal-variant=chip]")).toHaveCount(2);
    await expect(header.locator("[data-wallet-signal-variant=chip]").first()).toHaveAttribute("data-wallet-signal-state", /.+/);
  }
});

test("Sign in opens the auth modal in place, at 390 and 1280", async ({ page, request }) => {
  await reseed(request);
  for (const width of WIDTHS) {
    await at(page, width);
    await page.locator(HEADER).getByRole("link", { name: "Sign in", exact: true }).click();
    await expect.poll(() => page.evaluate(() => Alpine.store("modals").isOpen("auth"))).toBe(true);
    expect(new URL(page.url()).pathname).toBe("/contests");
    await page.evaluate(() => Alpine.store("modals").closeAll());
  }
});

test("signed in, the ✨ badge rides the avatar's upper-left corner, at 390 and 1280", async ({ page, request }) => {
  await reseed(request);
  await loginAdmin(page);
  for (const width of WIDTHS) {
    await at(page, width);
    const badge = page.locator(`${HEADER} [data-free-entry-badge]`);
    await expect(badge).toHaveCount(1);
    await page.evaluate(() => window.updateNavTokens(1));
    await expect(badge).toBeVisible();
    const b = await badge.boundingBox();
    // The avatar itself, not the account button, which holds the name too from md.
    const a = await page.locator(`${HEADER} [data-nav-account] > [aria-hidden]`).boundingBox();
    // Up and to the left of the avatar's corner, and still overlapping it.
    expect(b.x).toBeLessThan(a.x);
    expect(b.y).toBeLessThan(a.y);
    expect(b.x + b.width).toBeGreaterThan(a.x);
    expect(b.y + b.height).toBeGreaterThan(a.y);
  }
});

test("signed in, the avatar opens the gear sidebar, at 390 and 1280", async ({ page, request }) => {
  await reseed(request);
  await loginAdmin(page);
  for (const width of WIDTHS) {
    await at(page, width);
    const panel = page.locator(width < 768 ? "#gear-sidebar-mobile" : "#gear-sidebar");
    await expect(panel).toBeHidden();
    await page.locator(`${HEADER} [data-profile-image-toggle]`).click();
    await expect(panel).toBeVisible();
    // Still open a beat later: the panel closes on @click.outside.
    await page.waitForTimeout(300);
    await expect(panel).toBeVisible();
    await panel.getByRole("button", { name: "Close sidebar" }).click();
    await expect(panel).toBeHidden();
  }
});
