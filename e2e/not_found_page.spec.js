// [e2e] The friendly not-found page (task turf-adopts-not-found-page). A signed-out
// visitor on an unknown address gets a 404 naming Turf Monster inside Turf's layout,
// and the home button lands on /. The e2e server runs ENABLE_ERROR_PAGES=1
// (playwright.config.js, bin/e2e-parallel) to show the visitor's page, not the debug
// report. The engine page or public/404.html, whichever engine is locked: both carry
// the same words and data-test hooks.
const { test, expect } = require("@playwright/test");

test("a lost visitor sees the friendly not-found page, and its home button lands on /", async ({ page }) => {
  const pageErrors = [];
  const failures = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));
  page.on("response", (response) => {
    if (response.status() >= 400) {
      failures.push(`${response.status()} ${response.request().method()} ${response.url()}`);
    }
  });

  const response = await page.goto("/no-such-page");
  expect(response.status(), "a lost address answers 404, never a 200 or a redirect").toBe(404);
  expect(response.request().redirectedFrom(), "no redirect on the way").toBeNull();
  await expect(page).toHaveURL(/\/no-such-page$/);

  const lost = page.locator("[data-test='not-found']");
  await expect(lost).toBeVisible();
  await expect(lost.getByRole("heading", { level: 1 })).toHaveText("This page isn’t here");
  await expect(page).toHaveTitle("Page not found · Turf Monster");

  const home = lost.locator("a[data-test='not-found-home']");
  await expect(home).toHaveText("Back to Turf Monster");
  await expect(home).toHaveAttribute("href", "/");

  await home.click();
  await expect(page).toHaveURL(/\/$/);
  await expect(page.locator("[data-test='not-found']")).toHaveCount(0);

  // The lost address is the one failing request. Anything else (a missing logo, a
  // script the page could not load) fails here, and so does any script error.
  const lostAddress = failures.filter((line) => /^404 GET \S+\/no-such-page$/.test(line));
  expect(lostAddress, failures.join("\n")).toHaveLength(1);
  expect(failures.filter((line) => !lostAddress.includes(line))).toEqual([]);
  expect(pageErrors).toEqual([]);
});
