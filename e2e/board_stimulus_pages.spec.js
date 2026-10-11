const { test, expect } = require("@playwright/test");
const {
  login, loginAdmin, reseed, createActiveEntry, setQuestState, seedRailContests, clearRailContests
} = require("./helpers");

// [e2e] The contest page and the lobby, on the static Stimulus controllers that
// replaced their Alpine (contests/show, _turf_totals_leaderboard,
// _contest_header, _share_invite, contests/index, _contest_table).
//
// THE EARLY PRESS. These controllers are static (imported by turf_stimulus.js
// and preloaded on every page), so each spec presses AT ONCE: straight after
// goto, and straight after a Turbo visit renders the page, with no wait on the
// controller. Every controller and logic module answers 300 ms late, so a
// press made before its controller connected would be lost and the assertion
// after it would fail.
//
// The specs play on their own contest (e2e-rail-1, seeded and cleared here), so
// the entries they add reach no other spec's leaderboard.
const CONTEST = "/contests/e2e-rail-1";
let seq = 0;
const player = () => `board-stimulus-${Date.now()}-${seq++}@example.com`;

test.beforeEach(async ({ page, request }) => {
  await reseed(request);
  await seedRailContests(page, 1);
  await page.route(/\/assets\/(?:controllers|turf)\/[\w-]+\.js/, async (route) => {
    await new Promise((resolve) => setTimeout(resolve, 300));
    await route.continue();
  });
});

test.afterEach(async ({ page }) => await clearRailContests(page));

// A Turbo visit that stays in this document, resolving once the new page's
// `selector` has rendered (not merely the old one's).
async function turboVisit(page, path, selector) {
  await page.evaluate((s) => {
    window.__sameDocument = true;
    document.querySelectorAll(s).forEach((el) => (el.__beforeVisit = true));
  }, selector);
  await page.evaluate((p) => window.Turbo.visit(p), path);
  await page.waitForFunction((s) => {
    const el = document.querySelector(s);
    return !!el && !el.__beforeVisit;
  }, selector);
  expect(await page.evaluate(() => window.__sameDocument)).toBe(true);
}

async function signInWithEntry(page, picks = 0) {
  await login(page, player());
  await createActiveEntry(page, "e2e-rail-1", picks);
}

const tab = (page, key) => page.locator(`[data-tabs-target="tab"][data-tabs-key-param="${key}"]`);
const panel = (page, key) => page.locator(`[data-tabs-target="panel"][data-key="${key}"]`);
const leaderboard = (page) => page.locator('[data-controller="leaderboard"]');

test.describe("leaderboard and chat tabs", () => {
  test.use({ viewport: { width: 390, height: 844 } });

  test("Chat pressed straight after load shows the chat, and Leaderboard brings it back", async ({ page }) => {
    await page.goto(CONTEST);
    await tab(page, "chat").click();
    await expect(panel(page, "chat")).toBeVisible();
    await expect(panel(page, "leaderboard")).toBeHidden();
    await expect(tab(page, "chat")).toHaveClass(/bg-primary/);

    await tab(page, "leaderboard").click();
    await expect(panel(page, "leaderboard")).toBeVisible();
    await expect(panel(page, "chat")).toBeHidden();
  });

  test("Chat pressed straight after a Turbo visit, and Back starts on the leaderboard", async ({ page }) => {
    await page.goto("/contests");
    await turboVisit(page, CONTEST, '[data-controller~="tabs"]');
    await tab(page, "chat").click();
    await expect(panel(page, "chat")).toBeVisible();

    await turboVisit(page, "/contests", '[data-controller~="settled-filter"]');
    await page.goBack();
    await expect(page).toHaveURL(new RegExp(`${CONTEST}$`));
    await expect(panel(page, "leaderboard")).toBeVisible();
    await expect(panel(page, "chat")).toBeHidden();
  });
});

test.describe("leaderboard fold", () => {
  const tail = (page) => leaderboard(page).locator('[data-leaderboard-target="tail"]');

  test("Show all pressed straight after load unfolds every seat, and Show less folds it", async ({ page }) => {
    await page.goto(CONTEST);
    await page.getByText("Show all 29 seats").click();
    await expect(tail(page).first()).toBeVisible();
    await expect(page.getByText("Show all 29 seats")).toBeHidden();

    await page.getByRole("button", { name: /Show less/ }).click();
    await expect(tail(page).first()).toBeHidden();
    await expect(page.getByText("Show all 29 seats")).toBeVisible();
  });

  test("Show all pressed straight after a Turbo visit, and Back starts folded", async ({ page }) => {
    await page.goto("/contests");
    await turboVisit(page, CONTEST, '[data-controller="leaderboard"]');
    await page.getByText("Show all 29 seats").click();
    await expect(tail(page).first()).toBeVisible();

    await turboVisit(page, "/contests", '[data-controller~="settled-filter"]');
    await page.goBack();
    await expect(page).toHaveURL(new RegExp(`${CONTEST}$`));
    await expect(tail(page).first()).toBeHidden();
    await expect(page.getByText("Show all 29 seats")).toBeVisible();
  });
});

test.describe("leaderboard pills", () => {
  const picks = (page) => leaderboard(page).locator('[data-leaderboard-target="picks"]').first();

  test("at phone width the fan opens into the grid on a press straight after load", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await signInWithEntry(page, 3);
    await page.goto(CONTEST);
    const narrow = picks(page).locator('[data-leaderboard-target="narrow"]');
    await narrow.click();
    await expect(narrow.locator("> div")).toHaveClass(/grid-cols-3/);
    await expect(narrow.locator('[data-leaderboard-target="value"]').first()).toBeVisible();
    await expect(picks(page).locator('[data-leaderboard-target="full"]')).toBeHidden();

    await narrow.click();
    await expect(narrow.locator("> div")).toHaveClass(/\bflex\b/);
    await expect(narrow.locator('[data-leaderboard-target="value"]').first()).toBeHidden();
    await expect(narrow.locator('[data-leaderboard-target="pill"]').nth(1)).toHaveCSS("width", "80px");
  });

  test("the layout follows the column: the full row at desktop width, the fan after a resize", async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await signInWithEntry(page, 3);
    await page.goto(CONTEST);
    await expect(picks(page).locator('[data-leaderboard-target="full"]')).toBeVisible();
    await expect(picks(page).locator('[data-leaderboard-target="narrow"]')).toBeHidden();

    await page.setViewportSize({ width: 390, height: 844 });
    await expect(picks(page).locator('[data-leaderboard-target="narrow"]')).toBeVisible();
    await expect(picks(page).locator('[data-leaderboard-target="full"]')).toBeHidden();
  });
});

test.describe("contest header", () => {
  test("the actions menu opens on a press straight after load, and a press outside closes it", async ({ page }) => {
    await signInWithEntry(page);
    await page.goto(CONTEST);
    const trigger = page.getByRole("button", { name: "Contest actions" });
    await trigger.click();
    await expect(page.getByRole("link", { name: "Edit Entry" })).toBeVisible();
    await expect(trigger).toHaveAttribute("aria-expanded", "true");

    await page.locator("h1").first().click();
    await expect(page.getByRole("link", { name: "Edit Entry" })).toBeHidden();
    await expect(trigger).toHaveAttribute("aria-expanded", "false");
  });

  test("the actions menu opens on a press straight after a Turbo visit", async ({ page }) => {
    await signInWithEntry(page);
    await page.goto("/contests");
    await turboVisit(page, CONTEST, '[data-controller~="disclosure"]');
    await page.getByRole("button", { name: "Contest actions" }).click();
    await expect(page.getByRole("link", { name: "Edit Entry" })).toBeVisible();
  });

  test("the start time shows from the keyboard", async ({ page }) => {
    await page.goto(CONTEST);
    const start = page.getByRole("button", { name: "Show start time" });
    await start.focus();
    await page.keyboard.press("Enter");
    await expect(start).toHaveAttribute("aria-expanded", "true");
    await expect(page.locator('[data-disclosure-target="panel"]', { hasText: /Starts|TBD/ })).toBeVisible();
    await page.keyboard.press("Space");
    await expect(start).toHaveAttribute("aria-expanded", "false");
  });

  test("an admin's Lock in 60s hands the wallet the same slug and delay", async ({ page }) => {
    await loginAdmin(page);
    await page.goto(CONTEST);
    await page.evaluate(() => {
      window.__locks = [];
      window.lockContestViaPhantom = (...args) => window.__locks.push(args);
    });
    await page.getByRole("button", { name: "Lock", exact: true }).click();
    await page.getByRole("button", { name: "Lock in 60s" }).first().click();
    expect(await page.evaluate(() => window.__locks)).toEqual([["e2e-rail-1", 0], ["e2e-rail-1", 60]]);
  });
});

test.describe("share invite", () => {
  async function onInviteStep(page) {
    await signInWithEntry(page);
    await setQuestState(page, { username_changed: true, chat_sent: true, subscribed: true });
  }

  test("the how-it-works popover opens on a press straight after load; Escape and outside close it", async ({ page }) => {
    await onInviteStep(page);
    await page.goto(CONTEST);
    const info = page.getByRole("button", { name: "How invites work" });
    await info.click();
    await expect(page.getByText("How it works")).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(page.getByText("How it works")).toBeHidden();

    await info.click();
    await expect(page.getByText("How it works")).toBeVisible();
    await page.locator("h1").first().click();
    await expect(page.getByText("How it works")).toBeHidden();
  });

  test("Copy Link pressed straight after a Turbo visit copies the invite and says so", async ({ page, context }) => {
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    await onInviteStep(page);
    await page.goto("/contests");
    await turboVisit(page, CONTEST, '[data-controller~="copy-link"]');
    const button = page.locator('[data-copy-link-target="button"]');
    await button.click();
    await expect(button).toHaveText("Copied!");
    await expect(button).toHaveClass(/btn-secondary/);
    expect(await page.evaluate(() => navigator.clipboard.readText())).toContain("/contests/e2e-rail-1");
    await expect(button).toHaveText("Copy Link", { timeout: 3000 });
    await expect(button).toHaveClass(/btn-primary/);
  });
});

test.describe("lobby", () => {
  test("a contest row pressed straight after load opens its contest", async ({ page }) => {
    await page.goto("/contests");
    await page.locator('[data-contest-row="e2e-rail-1"] [data-contest-badge]').click();
    await expect(page).toHaveURL(new RegExp(`${CONTEST}$`));
  });

  test("an admin's Show Settled pressed straight after a Turbo visit flips, and Back starts off", async ({ page }) => {
    await loginAdmin(page);
    await page.goto(CONTEST);
    await turboVisit(page, "/contests", '[data-controller~="settled-filter"]');
    const toggle = page.locator('[data-settled-filter-target="toggle"]');
    await toggle.click();
    await expect(toggle).toHaveText("Hide Settled");
    await expect(toggle).toHaveAttribute("aria-pressed", "true");
    await expect(toggle).toHaveClass("btn btn-secondary");

    await turboVisit(page, CONTEST, '[data-controller="leaderboard"]');
    await page.goBack();
    await expect(page).toHaveURL(/\/contests$/);
    await expect(toggle).toHaveText("Show Settled");
    await expect(toggle).toHaveAttribute("aria-pressed", "false");
  });
});

test.describe("arrival and polling", () => {
  test("?add_entry=true brings the board into view", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await signInWithEntry(page);
    await page.goto(`${CONTEST}?add_entry=true`);
    await expect.poll(async () => page.evaluate(() => Math.round(document.getElementById("board").getBoundingClientRect().top))).toBeLessThan(200);
    expect(await page.evaluate(() => window.scrollY)).toBeGreaterThan(0);
  });

  test("a changed leaderboard is swapped in on the ninety-second poll", async ({ page }) => {
    await page.clock.install();
    await signInWithEntry(page);
    let asked = null;
    await page.route("**/c/e2e-rail-1/leaderboard_poll**", (route) => {
      asked = new URL(route.request().url()).searchParams.get("version");
      route.fulfill({ json: { changed: true, version: 42, html: '<p data-test="polled">fresh list</p>' } });
    });
    await page.goto(CONTEST);
    await page.clock.fastForward(90_000);
    await expect(page.locator('#leaderboard-container [data-test="polled"]')).toHaveText("fresh list");
    expect(Number(asked)).toBeGreaterThan(0);
    await expect(page.locator('[data-controller="leaderboard-poll"]')).toHaveAttribute("data-leaderboard-poll-version-value", "42");
  });
});
