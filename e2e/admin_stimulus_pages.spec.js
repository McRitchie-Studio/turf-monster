const { test, expect } = require("@playwright/test");
const { reseed, login, loginAdmin, lazyController } = require("./helpers");

// [e2e] The admin and dev pages that run on Turf's own Stimulus controllers
// (app/javascript/turf_stimulus.js). Each test presses the page's controls the
// way an operator does and reads what they do, then checks the page starts
// over after a Turbo visit and browser Back with one listener, not two.
//
// The drop announcement's send gate has its own spec
// (admin_drop_announcement.spec.js) and the live board's dev score tools are
// pressed throughout nfl_live_scoreboard.spec.js.
test.beforeEach(async ({ request }) => await reseed(request));

// Leaves by a Turbo visit to `via` and returns with the browser's Back button.
async function leaveAndComeBack(page, path, via = "/admin/hub") {
  await page.evaluate((to) => window.Turbo.visit(to), via);
  await page.waitForURL(`**${via}`);
  await expect(page.locator(`[data-controller="${via === "/admin/hub" ? "hub-actions" : "filter"}"]`)).toBeVisible();
  await page.goBack();
  await page.waitForURL(`**${path}`);
}

test("the schema page filters its tables by name, by mouse and by keyboard", async ({ page }) => {
  await loginAdmin(page);
  await page.goto("/admin/schema");
  await lazyController(page, "filter");

  const input = page.getByPlaceholder("Filter tables...");
  const cards = page.locator('[data-filter-target="item"]:visible');
  const clear = page.locator('[data-filter-target="clear"]');
  const empty = page.locator('[data-filter-target="empty"]');
  const total = await cards.count();
  expect(total).toBeGreaterThan(10);
  await expect(clear).toBeHidden();
  await expect(empty).toBeHidden();

  await input.fill("USER");
  await expect(cards).toHaveCount(1);
  await expect(cards.locator("h3")).toHaveText("users");
  await expect(clear).toBeVisible();

  await input.fill("zzzz");
  await expect(cards).toHaveCount(0);
  await expect(empty).toBeVisible();
  await expect(empty).toContainText('No tables matching "zzzz"');

  await input.press("Escape");
  await expect(input).toHaveValue("");
  await expect(cards).toHaveCount(total);
  await expect(clear).toBeHidden();
  await expect(empty).toBeHidden();

  await input.fill("contest");
  await input.press("Tab");
  await expect(clear).toBeFocused();
  await page.keyboard.press("Enter");
  await expect(input).toHaveValue("");
  await expect(cards).toHaveCount(total);

  await input.fill("slate");
  await expect(cards).not.toHaveCount(total);
  await leaveAndComeBack(page, "/admin/schema");
  await expect(input).toHaveValue("");
  await expect(cards).toHaveCount(total);
  await expect(clear).toBeHidden();
  await input.fill("user");
  await expect(cards).toHaveCount(1);
});

test("the dashboard shows five users and reveals the rest on Show more", async ({ page, browser, baseURL }) => {
  // A sixth account, so there is a rest to reveal: the seed has five.
  const context = await browser.newContext({ baseURL });
  const visitor = await context.newPage();
  await login(visitor, `show-more-${Date.now()}@example.com`);
  await context.close();

  await loginAdmin(page);
  await page.goto("/admin/dashboard");
  await lazyController(page, "show-more");

  const card = page.locator('[data-controller="show-more"]');
  const rows = card.locator("ul > li:visible");
  const button = card.getByRole("button");
  const more = button.locator('[data-show-more-target="more"]');
  const less = button.locator('[data-show-more-target="less"]');
  const collapsed = async () => {
    await expect(rows).toHaveCount(5);
    await expect(more).toBeVisible();
    await expect(more).toHaveText(/^Show more \(\d+\)$/);
    await expect(less).toBeHidden();
  };
  const expanded = async () => {
    await expect(less).toBeVisible();
    await expect(more).toBeHidden();
    expect(await rows.count()).toBeGreaterThan(5);
  };
  await collapsed();

  await button.click();
  await expanded();
  await button.click();
  await collapsed();

  await button.focus();
  await page.keyboard.press("Space");
  await expanded();

  await leaveAndComeBack(page, "/admin/dashboard");
  await collapsed();
  await button.click();
  await expanded();
});

test("the hub's Refresh Balance and Replay Level each act once per press", async ({ page }) => {
  await loginAdmin(page);
  await page.goto("/admin/hub");
  await lazyController(page, "hub-actions");

  // A cache-cold navbar reads the balance itself, and a second read is refused
  // while one is out: wait for the pill before pressing.
  await expect(page.locator("[data-balance-display]").first()).toHaveText(/\$\d/);

  // The balance read is held until the spinner has been seen over it.
  let release = null;
  let reads = 0;
  await page.route(/\/admin\/usdc_balance/, async (route) => {
    reads += 1;
    await new Promise((resolve) => { release = resolve; });
    await route.continue();
  });
  const spinner = page.locator(".nav-spinner-icon").first();
  await page.getByRole("button", { name: "Refresh Balance" }).click();
  await expect(spinner).toHaveCSS("opacity", "1");
  expect(reads).toBe(1);
  release();
  await expect(spinner).toHaveCSS("opacity", "0");
  await page.unroute(/\/admin\/usdc_balance/);

  await page.evaluate(() => {
    window.__replays = [];
    window.addEventListener("navbar-replay-level", (event) => {
      window.__replays.push({ bubbles: event.bubbles, composed: event.composed, from: event.target.textContent.trim() });
    });
  });
  await page.getByRole("button", { name: "Replay Level" }).click();
  expect(await page.evaluate(() => window.__replays)).toEqual([{ bubbles: true, composed: true, from: "Replay Level" }]);

  await leaveAndComeBack(page, "/admin/hub", "/admin/schema");
  await page.evaluate(() => { window.__replays = []; });
  await page.getByRole("button", { name: "Replay Level" }).focus();
  await page.keyboard.press("Enter");
  expect(await page.evaluate(() => window.__replays.length)).toBe(1);
});

test("the drop announcement's send gate starts over after Back", async ({ page }) => {
  await page.request.post("/test/seed_drop_signups", { form: { "emails[]": `e2e-gate-${Date.now()}@example.com` } });
  await loginAdmin(page);
  await page.goto("/admin/drop_signups/announcement");

  const count = Number((await page.locator('[data-test="announcement-recipient-count"]').innerText()).replace(/,/g, ""));
  const send = page.locator('[data-test="announcement-send"]');
  const typed = page.locator('[data-test="announcement-confirm-count"]');
  const early = page.locator('[data-test="announcement-send-early"]');
  await expect(send).toBeDisabled();

  await typed.fill(` ${count} `);
  if (await early.count()) {
    await expect(send).toBeDisabled();
    await early.focus();
    await page.keyboard.press("Space");
  }
  await expect(send).toBeEnabled();

  let asked = null;
  page.once("dialog", async (dialog) => { asked = dialog.message(); await dialog.dismiss(); });
  await send.click();
  expect(asked).toContain(`Send the drop announcement to ${count} address`);
  await expect(page).toHaveURL(/\/admin\/drop_signups\/announcement$/);

  await leaveAndComeBack(page, "/admin/drop_signups/announcement");
  await expect(typed).toHaveValue("");
  if (await early.count()) await expect(early).not.toBeChecked();
  await expect(send).toBeDisabled();
});

test("the seeds lab fills, levels up and restyles its shine", async ({ page }) => {
  await loginAdmin(page);
  await page.goto("/seeds_lab");
  await lazyController(page, "seeds-lab");

  const label = (name) => page.locator(`[data-label="${name}"]`).first();
  const simulator = page.locator('[data-seeds-lab-target="simButton"]');
  const shimmer = page.locator('[data-seeds-lab-target="shimmer"]');
  await expect(label("shineDebug")).toHaveText("seedsShimmer 2.5s ease-in-out 0s infinite");
  await expect(shimmer.first()).toBeVisible();

  await page.getByRole("button", { name: "+25" }).click();
  await expect(label("seeds")).toHaveText("25");
  await expect(label("seedsOf")).toHaveText("25 / 100 seeds");
  await expect(label("sections")).toHaveText("1 / 5 sections");
  await expect(page.locator('[data-style="progress"]').first()).toHaveAttribute("style", /--bar-progress: 25/);

  await page.getByRole("button", { name: "Jump" }).click();
  await expect(label("toward")).toHaveText("95");
  await expect(page.locator('[data-seeds-lab-target="sprout"]')).toHaveText(["🌳", "🌳", "🌳", "🌳", "🌱"]);

  await page.getByRole("button", { name: "+19" }).click();
  await expect(simulator.first()).toBeDisabled();
  await expect(label("toward")).toHaveText("100");
  await expect(label("levelBadge")).toHaveClass(/level-up-pop/);
  await expect(label("level")).toHaveText("2", { timeout: 5000 });
  await expect(label("toward")).toHaveText("14", { timeout: 5000 });
  await expect(simulator.first()).toBeEnabled();
  await expect(label("levelBadge")).toHaveText("Level 2");
  await expect(label("levelBadge")).not.toHaveClass(/level-up-pop/);
  await expect(label("seeds")).toHaveText("114");

  const mode = page.locator('[data-seeds-lab-target="mode"]');
  const interval = page.locator('[data-seeds-lab-target="interval"]');
  await expect(interval).toBeHidden();
  await mode.selectOption("pulse");
  await expect(interval).toBeVisible();
  await interval.fill("8");
  await expect(label("shineInterval")).toHaveText("8s");
  await expect(label("shineIntervalHint")).toHaveText("(shine ≈ 2.0s)");
  await expect(label("shineDebug")).toHaveText("seedsShimmerPulse 8s ease-in-out 0s infinite");
  await expect(shimmer.first()).toHaveCSS("animation-name", "seedsShimmerPulse");
  await mode.selectOption("off");
  await expect(shimmer.first()).toBeHidden();
  await expect(label("shineDebug")).toHaveText("animation: none");
  await mode.selectOption("once");
  await expect(shimmer.first()).toBeVisible();
  await expect(shimmer.first()).toHaveCSS("animation-iteration-count", "1");
  await page.getByRole("button", { name: "Trigger now" }).click();
  await expect(shimmer.first()).toBeVisible();

  await page.getByRole("button", { name: "Reset" }).focus();
  await page.keyboard.press("Enter");
  await expect(label("seeds")).toHaveText("0");
  await expect(label("levelBadge")).toHaveText("Level 1");

  await page.getByRole("button", { name: "+14" }).click();
  await leaveAndComeBack(page, "/seeds_lab");
  await expect(label("seeds")).toHaveText("0");
  await expect(mode).toHaveValue("continuous");
  await page.getByRole("button", { name: "+25" }).click();
  await expect(label("seeds")).toHaveText("25");
});

test("the toast test page fires each toast once, and a toast's button fires its follow-up", async ({ page }) => {
  await loginAdmin(page);
  await page.goto("/toast_test");
  await lazyController(page, "toast-demo");

  const toasts = page.locator(".toast-card");
  await page.getByRole("button", { name: "Success", exact: true }).click();
  await expect(toasts).toHaveCount(1);
  await expect(toasts.first()).toContainText("Entry confirmed successfully.");

  await page.reload();
  await lazyController(page, "toast-demo");
  await page.getByRole("button", { name: "Invite (Accept / Decline)" }).click();
  await expect(toasts.first()).toContainText("Alex invited you to Matchday 2.");
  await toasts.getByRole("button", { name: "Accept" }).click();
  await expect(toasts.filter({ hasText: "You joined Matchday 2." })).toHaveCount(1);

  await page.reload();
  await lazyController(page, "toast-demo");
  await page.getByRole("button", { name: "Fire 3 Toasts" }).click();
  await expect(toasts).toHaveCount(3);
  await expect(toasts).toContainText(["Game locks in 5 minutes.", "Payment confirmed.", "Entry submitted."]);

  await leaveAndComeBack(page, "/toast_test");
  const before = await toasts.count();
  await page.getByRole("button", { name: "Permanent" }).focus();
  await page.keyboard.press("Enter");
  await expect(toasts).toHaveCount(before + 1);
});

// The console's writes are answered here: the endpoints are pinned in
// test/controllers/admin, and a real goal or a real FINAL would outlive this
// spec in the lane's shared database.
test("the goal console records, removes and finalises through one card, and filters the rest", async ({ page }) => {
  const sent = [];
  let answer = null;
  await page.route("**/admin/games/**", async (route) => {
    const request = route.request();
    sent.push({ method: request.method(), path: new URL(request.url()).pathname, body: request.postDataJSON() });
    await new Promise((resolve) => setTimeout(resolve, 300));
    await route.fulfill({ status: answer.status || 200, contentType: "application/json", body: JSON.stringify(answer.body) });
  });
  const game = (change) => ({ success: true, game: { homeScore: 1, awayScore: 0, status: "in_progress", goals: [], ...change } });

  await loginAdmin(page);
  await page.goto("/admin/scoring");
  await lazyController(page, "game-scorer");
  await lazyController(page, "scoring-filter");

  const cards = page.locator('[data-scoring-filter-target="card"]:visible');
  const total = await cards.count();
  expect(total).toBeGreaterThan(1);
  const card = page.locator('[data-scoring-filter-target="card"]').first();
  const slug = JSON.parse(await card.getAttribute("data-game-scorer-game-value")).slug;
  const score = card.locator('[data-game-scorer-target="score"]');
  const status = card.locator('[data-game-scorer-target="status"]');
  const minute = card.locator('[data-game-scorer-target~="minute"]');
  const pills = card.locator('[data-game-scorer-target="goals"] > span');
  const complete = card.locator('[data-game-scorer-target="complete"]');
  await expect(score).toHaveText("– – –");
  await expect(status).toHaveText("Scheduled");
  await expect(complete).toHaveText("Mark Final");
  await expect(pills).toHaveCount(0);

  answer = { body: game({ goals: [{ id: 901, teamEmoji: "🏈", minute: 12 }] }) };
  await minute.fill("12");
  await card.locator('[data-game-scorer-side-param="home"]').click();
  await expect(minute).toBeDisabled();
  await expect(complete).toBeDisabled();
  await expect(minute).toHaveValue("");
  await expect(score).toHaveText("1 – 0");
  await expect(status).toHaveText("LIVE");
  await expect(pills).toHaveCount(1);
  await expect(pills.first()).toHaveText(/🏈\s*12’/);
  await expect(minute).toBeEnabled();
  expect(sent.at(-1)).toMatchObject({ method: "POST", path: `/admin/games/${slug}/goals`, body: { minute: 12 } });
  expect(sent.at(-1).body.team_slug).toBeTruthy();

  answer = { body: game({ homeScore: 0, goals: [] }) };
  await pills.first().getByRole("button").click();
  await expect(pills).toHaveCount(0);
  expect(sent.at(-1)).toMatchObject({ method: "DELETE", path: `/admin/games/${slug}/goals/901` });

  answer = { status: 422, body: { success: false, error: "Minute is not a number" } };
  await card.locator('[data-game-scorer-side-param="away"]').click();
  await expect(card.locator('[data-game-scorer-target="error"]')).toHaveText("Minute is not a number");
  expect(sent.at(-1).body.minute).toBe("");

  const before = sent.length;
  page.once("dialog", (dialog) => dialog.dismiss());
  await complete.click();
  expect(sent.length).toBe(before);

  answer = { body: game({ homeScore: 0, status: "completed" }) };
  page.once("dialog", (dialog) => dialog.accept());
  await complete.focus();
  await page.keyboard.press("Enter");
  await expect(status).toHaveText("FINAL");
  await expect(status).toHaveClass(/text-emerald-400/);
  await expect(complete).toHaveText("Final ✓");
  await expect(complete).toBeDisabled();
  expect(sent.at(-1)).toMatchObject({ method: "POST", path: `/admin/games/${slug}/complete` });

  const hide = page.getByLabel("Hide finished");
  const query = page.getByPlaceholder("Filter by team…");
  await hide.check();
  await expect(card).toBeHidden();
  await expect(cards).toHaveCount(total - 1);
  await hide.uncheck();
  await expect(card).toBeVisible();
  await query.fill("zzzzzz");
  await expect(cards).toHaveCount(0);
  await query.fill((await card.getAttribute("data-search")).split(" ")[0].toUpperCase());
  await expect(card).toBeVisible();
  expect(await cards.count()).toBeLessThan(total);

  await leaveAndComeBack(page, "/admin/scoring");
  await expect(query).toHaveValue("");
  await expect(cards).toHaveCount(total);
  await expect(status).toHaveText("Scheduled");
  await expect(status).not.toHaveClass(/text-emerald-400/);
  const posts = sent.length;
  answer = { body: game({}) };
  await card.locator('[data-game-scorer-side-param="home"]').click();
  await expect(score).toHaveText("1 – 0");
  expect(sent.length).toBe(posts + 1);
});

test("each navbar preview resizes, fits its device and toggles Scrolled on its own", async ({ page }) => {
  await loginAdmin(page);
  await page.goto("/admin/navbar");
  await lazyController(page, "navbar-preview");

  const cards = page.locator('[data-controller="navbar-preview"]');
  await expect(cards).toHaveCount(6);
  const card = cards.first();
  const other = cards.nth(1);
  const label = card.locator('[data-navbar-preview-target="label"]');
  const slider = card.locator('[data-navbar-preview-target="slider"]');
  const frame = card.locator('[data-navbar-preview-target="frame"]');
  const toggle = card.getByRole("button", { name: "Scrolled" });
  await expect(label).toHaveText("390px");
  await expect(frame).toHaveCSS("width", "390px");

  await slider.focus();
  await page.keyboard.press("ArrowRight");
  await page.keyboard.press("ArrowRight");
  await expect(label).toHaveText("392px");
  await expect(frame).toHaveCSS("width", "392px");
  await slider.fill("350");
  await expect(label).toHaveText("350px");
  await expect(other.locator('[data-navbar-preview-target="label"]')).toHaveText("430px");

  await toggle.click();
  await expect(frame).toHaveClass(/is-scrolled-preview/);
  await expect(toggle).toHaveClass(/bg-primary/);
  expect(await frame.evaluate((el) => el.style.getPropertyValue("--nav-p"))).toBe("1");
  await toggle.focus();
  await page.keyboard.press("Enter");
  await expect(frame).not.toHaveClass(/is-scrolled-preview/);
  await expect(toggle).toHaveClass(/bg-surface-alt/);
  await toggle.click();

  await card.getByRole("button", { name: "iPhone 15 (390px)" }).click();
  await expect(label).toHaveText("390px");
  await expect(slider).toHaveValue("390");
  await expect(frame).toHaveClass(/is-scrolled-preview/);

  await slider.fill("360");
  await leaveAndComeBack(page, "/admin/navbar");
  await expect(label).toHaveText("390px");
  await expect(slider).toHaveValue("390");
  await expect(frame).not.toHaveClass(/is-scrolled-preview/);
  await toggle.click();
  await expect(frame).toHaveClass(/is-scrolled-preview/);
});
