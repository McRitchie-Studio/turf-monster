const { test, expect } = require("@playwright/test");
const { reseed, loginAdmin } = require("./helpers");

// [e2e] Two pages on the engine page header (task turf-standard-page-headers): the
// help glossary, a public page whose "← Help Center" link is now the crumb trail, and
// /admin/drop_signups, an admin page whose two buttons are now the header's action and
// its Links menu. At desktop width and at 390px: the row, main's one h1, the trail
// (one parent link on a phone), the controls, and no sideways scroll.
test.beforeEach(async ({ request }) => await reseed(request));

const VIEWPORTS = {
  desktop: { name: "desktop", width: 1440, height: 900 },
  phone: { name: "phone", width: 390, height: 844 },
};

async function noSidewaysScroll(page) {
  expect(await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)).toBeLessThanOrEqual(0);
}

async function expectTrail(page, viewport, labels, parentHref) {
  const row = page.locator(".page-header");
  if (viewport.name === "desktop") {
    await expect(row.locator(".page-header-crumbs li")).toHaveText(labels);
    await expect(row.locator(".page-header-parent")).toBeHidden();
  } else {
    await expect(row.locator(".page-header-crumbs")).toBeHidden();
    const parent = row.locator(".page-header-parent");
    await expect(parent).toBeVisible();
    await expect(parent).toHaveText(new RegExp(labels[labels.length - 2]));
    await expect(parent).toHaveAttribute("href", parentHref);
  }
}

async function glossary(page, viewport) {
  await page.setViewportSize({ width: viewport.width, height: viewport.height });
  await page.goto("/help/glossary");

  const row = page.locator(".page-header");
  await expect(row).toBeVisible();
  await expect(page.locator("main h1")).toHaveCount(1);
  await expect(row.locator("h1.page-header-title")).toHaveText("Glossary");
  await expectTrail(page, viewport, ["Help Center", "Glossary"], "/help");
  await expect(page.locator("main dl")).toBeVisible();
  await noSidewaysScroll(page);

  // The trail goes where the old back link went.
  const link = viewport.name === "desktop" ? row.locator("a.page-header-crumb") : row.locator("a.page-header-parent");
  await link.click();
  await expect(page).toHaveURL(/\/help$/);
  await expect(page.locator(".page-header h1.page-header-title")).toHaveText("Help Center");
}

async function dropSignups(page, viewport) {
  await loginAdmin(page);
  await page.setViewportSize({ width: viewport.width, height: viewport.height });
  await page.goto("/admin/drop_signups");

  const row = page.locator(".page-header");
  await expect(row).toBeVisible();
  await expect(page.locator("main h1")).toHaveCount(1);
  await expect(row.locator("h1.page-header-title")).toHaveText("Drop Signups");
  await expectTrail(page, viewport, ["Admin", "Drop Signups"], "/admin/hub");

  const action = row.locator("a.page-header-action");
  await expect(action).toBeVisible();
  await expect(action).toHaveText("Send drop announcement");

  const button = row.locator(".page-header-menu-button");
  const list = row.locator(".page-header-menu-list");
  await expect(list).toBeHidden();
  await button.click();
  await expect(list).toBeVisible();
  await expect(list.locator("a")).toHaveText(["Export CSV"]);
  const box = await list.boundingBox();
  expect(box.x).toBeGreaterThanOrEqual(0);
  expect(box.x + box.width).toBeLessThanOrEqual(viewport.width);
  await page.keyboard.press("Escape");
  await expect(list).toBeHidden();
  await noSidewaysScroll(page);

  await action.click();
  await expect(page).toHaveURL(/\/admin\/drop_signups\/announcement$/);
  await expect(page.locator(".page-header h1.page-header-title")).toHaveText("Drop Announcement");
}

// Written as literal tests, not a loop: bin/e2e-executed-set-check counts `test(` calls in the source.
test("the help glossary at desktop: the header, its trail to the Help Center, and one h1", async ({ page }) => {
  await glossary(page, VIEWPORTS.desktop);
});

test("the help glossary at 390px: the header, its parent link, and no sideways scroll", async ({ page }) => {
  await glossary(page, VIEWPORTS.phone);
});

test("/admin/drop_signups at desktop: the trail, the action and the Links menu", async ({ page }) => {
  await dropSignups(page, VIEWPORTS.desktop);
});

test("/admin/drop_signups at 390px: the parent link, the action and a menu inside the viewport", async ({ page }) => {
  await dropSignups(page, VIEWPORTS.phone);
});
