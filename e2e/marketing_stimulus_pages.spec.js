const { test, expect } = require("@playwright/test");

// [e2e] The public pages that left Alpine for static Stimulus controllers.
//
// THE EARLY PRESS. A lazy controller drops a press made before its module
// registers. These controllers are static (imported by turf_stimulus.js and
// preloaded on every page), so each spec here presses AT ONCE: straight after
// goto, and straight after a Turbo visit renders the page, with no wait on the
// controller. A press that is lost fails the assertion that follows it.
// Signed out throughout: these are visitor pages.
//
// Every controller and logic module answers 300 ms late, so the specs bite: a
// preloaded module holds the page's load until it has run, while a lazy one is
// fetched only after the page has loaded, and a press in that window is lost.
test.beforeEach(async ({ page }) => {
  await page.route(/\/assets\/(?:controllers|turf)\/[\w-]+\.js/, async (route) => {
    await new Promise((resolve) => setTimeout(resolve, 300));
    await route.continue();
  });
});

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

test.describe("how to play accordion", () => {
  const button = (page, name) => page.getByRole("button", { name, exact: true });
  const panel = (page, key) => page.locator(`[data-accordion-target="panel"][data-key="${key}"]`);

  test("a press straight after load opens one section at a time", async ({ page }) => {
    await page.goto("/help/how-to-play");
    await button(page, "Picks").click();
    await expect(panel(page, "picks")).toBeVisible();
    await expect(panel(page, "picks")).toContainText("Each contest shows a slate");
    await expect(page.locator('[data-accordion-target="icon"][data-key="picks"]')).toHaveClass(/rotate-180/);

    await button(page, "Scoring").click();
    await expect(panel(page, "scoring")).toBeVisible();
    await expect(panel(page, "picks")).toBeHidden();

    await button(page, "Scoring").click();
    await expect(panel(page, "scoring")).toBeHidden();
  });

  test("the keyboard opens a section", async ({ page }) => {
    await page.goto("/help/how-to-play");
    await button(page, "Payouts").focus();
    await page.keyboard.press("Enter");
    await expect(panel(page, "payouts")).toBeVisible();
    await page.keyboard.press("Space");
    await expect(panel(page, "payouts")).toBeHidden();
  });

  test("a press straight after a Turbo visit opens, and Back starts all closed", async ({ page }) => {
    await page.goto("/help");
    await turboVisit(page, "/help/how-to-play", '[data-controller="accordion"]');
    await button(page, "Turf Scores").click();
    await expect(panel(page, "turfScores")).toBeVisible();

    await turboVisit(page, "/help", 'a[href="/help/how-to-play"]');
    await page.goBack();
    await expect(page).toHaveURL(/\/help\/how-to-play$/);
    await expect(panel(page, "turfScores")).toBeHidden();
  });
});

test.describe("card filters", () => {
  const visibleTeams = (page, league) => page.locator(`[data-team-card][data-league="${league}"]:visible`);

  test("teams: the NFL pill pressed straight after load narrows the grid", async ({ page }) => {
    await page.goto("/teams");
    await page.getByRole("button", { name: "NFL", exact: true }).click();
    await expect(visibleTeams(page, "fifa")).toHaveCount(0);
    await expect(visibleTeams(page, "nfl")).toHaveCount(32);
    await expect(page.locator('[data-card-filter-target="count"]')).toHaveText("32 teams");
    await expect(page.getByRole("button", { name: "NFL", exact: true })).toHaveAttribute("aria-pressed", "true");
    await expect(page.getByRole("button", { name: "All", exact: true })).toHaveClass(/btn-outline/);

    await page.getByPlaceholder("Search teams...").fill("buffalo");
    await expect(page.locator("[data-team-card]:visible")).toHaveCount(1);
    await expect(page.locator('[data-card-filter-target="count"]')).toHaveText("1 teams");
  });

  test("teams: a pill pressed straight after a Turbo visit filters, and Back starts unfiltered", async ({ page }) => {
    await page.goto("/help");
    await turboVisit(page, "/teams", '[data-controller="card-filter"]');
    await page.getByRole("button", { name: "NFL", exact: true }).click();
    await expect(visibleTeams(page, "fifa")).toHaveCount(0);

    await turboVisit(page, "/help", 'a[href="/help/how-to-play"]');
    await page.goBack();
    await expect(page).toHaveURL(/\/teams$/);
    await expect(page.getByRole("button", { name: "All", exact: true })).toHaveAttribute("aria-pressed", "true");
    await expect(visibleTeams(page, "fifa")).not.toHaveCount(0);
  });

  test("players: a position pressed straight after load, and again after a Turbo visit", async ({ page }) => {
    await page.goto("/players");
    const total = await page.locator("[data-player-card]").count();
    expect(total).toBeGreaterThan(0);
    await expect(page.locator('[data-card-filter-target="count"]')).toHaveText(`${total} players`);

    await page.getByRole("button", { name: "Goalkeeper", exact: true }).click();
    const keepers = page.locator('[data-player-card]:visible');
    await expect(keepers).not.toHaveCount(0);
    for (const position of await keepers.evaluateAll((els) => els.map((e) => e.dataset.position))) {
      expect(position).toBe("Goalkeeper");
    }

    await turboVisit(page, "/players?from=turbo", '[data-controller="card-filter"]');
    await page.getByRole("button", { name: "Forward", exact: true }).click();
    const forwards = page.locator('[data-player-card]:visible');
    await expect(forwards).not.toHaveCount(0);
    for (const position of await forwards.evaluateAll((els) => els.map((e) => e.dataset.position))) {
      expect(position).toBe("Forward");
    }
  });

  test("nfl players: a search typed straight after load narrows the roster", async ({ page }) => {
    await page.goto("/nfl-players?team=buffalo-bills");
    await page.getByPlaceholder("Search players...").fill("shakir");
    await expect(page.locator("[data-athlete-card]:visible")).toHaveCount(1);
    await expect(page.locator('[data-card-filter-target="count"]')).toHaveText("1 players");

    await turboVisit(page, "/nfl-players?team=buffalo-bills&from=turbo", '[data-controller="card-filter"]');
    await page.getByPlaceholder("Search players...").fill("cook");
    await expect(page.locator("[data-athlete-card]:visible")).toHaveCount(1);
    await expect(page.locator("[data-athlete-card]:visible")).toContainText("James Cook");
  });
});

test.describe("team swatches", () => {
  test.use({ permissions: [ "clipboard-read", "clipboard-write" ] });

  test("hover shows the hex, a press straight after load copies it", async ({ page }) => {
    await page.goto("/teams");
    const swatch = page.locator('[data-team-card]', { hasText: "Buffalo Bills" }).locator('button[aria-label="Copy #00338D"]');
    const tip = swatch.locator('[data-swatch-copy-target="tip"]');

    await swatch.click();
    await expect(tip).toHaveText("Copied!");
    await expect(tip).toBeVisible();
    expect(await page.evaluate(() => navigator.clipboard.readText())).toBe("#00338D");

    await page.mouse.move(0, 0);
    await expect(tip).toBeHidden();
    await swatch.hover();
    await expect(tip).toBeVisible();
    await expect(tip).toHaveText("#00338D");
  });

  test("a press straight after a Turbo visit copies", async ({ page }) => {
    await page.goto("/help");
    await turboVisit(page, "/teams", '[data-controller="swatch-copy"]');
    const swatch = page.locator('[data-team-card]', { hasText: "Buffalo Bills" }).locator('button[aria-label="Copy #C60C30"]');
    await swatch.click();
    await expect(swatch.locator('[data-swatch-copy-target="tip"]')).toHaveText("Copied!");
  });
});

test.describe("contract cost calculator", () => {
  // The dollars the calculator should show for `price`, from the lamports the
  // page hands its controller.
  async function expected(page, price) {
    return page.locator('[data-controller="cost-calculator"]').evaluate((root, p) => {
      const perm = Number(root.dataset.costCalculatorPermLamportsValue) / 1e9;
      const float = Number(root.dataset.costCalculatorFloatLamportsValue) / 1e9;
      return {
        floatUsd: "$" + Math.round(float * p).toLocaleString(),
        permUsd: "~$" + Math.round(perm * p).toLocaleString()
      };
    }, price);
  }
  const figure = (page, name) => page.locator(`[data-cost-calculator-target="output"][data-figure="${name}"]`);

  test("prices at the default straight away, and a price typed straight after load reprices", async ({ page }) => {
    await page.goto("/contract");
    const at165 = await expected(page, 165);
    await expect(figure(page, "floatUsd")).toHaveText(at165.floatUsd);

    await page.locator('[data-cost-calculator-target="price"]').fill("200");
    const at200 = await expected(page, 200);
    await expect(figure(page, "floatUsd")).toHaveText(at200.floatUsd);
    await expect(figure(page, "permUsd")).toHaveText(at200.permUsd);
    await expect(figure(page, "permSol")).toHaveText(/^~\d+\.\d{3} SOL$/);
  });

  test("a price typed straight after a Turbo visit reprices, and Back starts at the default", async ({ page }) => {
    await page.goto("/help");
    await turboVisit(page, "/contract", '[data-controller="cost-calculator"]');
    await page.locator('[data-cost-calculator-target="price"]').fill("300");
    await expect(figure(page, "floatUsd")).toHaveText((await expected(page, 300)).floatUsd);

    await turboVisit(page, "/help", 'a[href="/help/how-to-play"]');
    await page.goBack();
    await expect(page).toHaveURL(/\/contract$/);
    await expect(page.locator('[data-cost-calculator-target="price"]')).toHaveValue("165");
    await expect(figure(page, "floatUsd")).toHaveText((await expected(page, 165)).floatUsd);
  });
});

test.describe("drop unsubscribe", () => {
  test("the emailed link unsubscribes on arrival, on a full load and after a Turbo visit", async ({ page }) => {
    const stamp = Date.now();
    const res = await page.request.post("/test/seed_drop_signups", {
      data: { emails: [ `unsub-load-${stamp}@example.com`, `unsub-turbo-${stamp}@example.com` ] }
    });
    expect(res.ok()).toBe(true);
    const [ loadToken, turboToken ] = (await res.json()).unsubscribe_tokens;

    await page.goto(`/drop-signups/unsubscribe/${loadToken}`);
    await expect(page.locator('[data-test="drop-unsubscribe-done"]')).toBeVisible();

    await page.goto("/help");
    await page.evaluate((t) => window.Turbo.visit(`/drop-signups/unsubscribe/${t}`), turboToken);
    await expect(page.locator('[data-test="drop-unsubscribe-done"]')).toBeVisible();
  });
});

test.describe("proof of reserves", () => {
  // A Contest account in the turf-vault layout decodeContest reads: Open,
  // season 7, a $150 guaranteed prize paid 100/50, a $19 fee, 12 of 30 entries.
  function contestAccountBase64() {
    const size = 8 + 32 * 3 + 4 + 8 + 8 * 16 + 8 * 16 + 4 + 4 + 1 + 4 + 8 * 2 + 1 + 8 + 8 + 16;
    const bytes = Buffer.alloc(size);
    let o = 8 + 32 * 3;
    bytes.writeUInt32LE(7, o); o += 4;
    bytes.writeBigUInt64LE(150_000_000n, o); o += 8;
    bytes.writeBigUInt64LE(19_000_000n, o); o += 8 * 16;
    o += 8 * 16;
    bytes.writeUInt32LE(30, o); o += 4;
    bytes.writeUInt32LE(12, o); o += 4;
    bytes.writeUInt8(0, o); o += 1;
    bytes.writeUInt32LE(2, o); o += 4;
    bytes.writeBigUInt64LE(100_000_000n, o); o += 8;
    bytes.writeBigUInt64LE(50_000_000n, o);
    return bytes.toString("base64");
  }

  // Answers the page's RPC reads, holding every answer until `release` runs.
  async function fakeChain(page) {
    const html = await (await page.request.get("/proof-of-reserves")).text();
    const rpcUrl = html.match(/data-proof-of-reserves-rpc-url-value="([^"]*)"/)[1].replace(/&amp;/g, "&");
    const chain = { reads: 0 };
    let open;
    const gate = new Promise((resolve) => (open = resolve));
    chain.release = () => open();
    await page.route(rpcUrl, async (route) => {
      const call = route.request().postDataJSON();
      await gate;
      const value = call.method === "getAccountInfo"
        ? (chain.reads += 1, { data: [ contestAccountBase64(), "base64" ], executable: false, lamports: 1, owner: "11111111111111111111111111111111", rentEpoch: 0, space: 0 })
        : { amount: "150000000", decimals: 6, uiAmount: 150, uiAmountString: "150" };
      await route.fulfill({ contentType: "application/json", body: JSON.stringify({ jsonrpc: "2.0", id: call.id, result: { context: { slot: 1 }, value } }) });
    });
    return chain;
  }

  test.beforeEach(async ({ page }) => {
    const res = await page.request.post("/test/seed_contests", { data: { count: 1, onchain: true } });
    expect(res.ok()).toBe(true);
  });
  test.afterEach(async ({ page }) => {
    await page.request.post("/test/clear_seeded_contests");
  });

  const row = (page) => page.locator('[data-proof-of-reserves-target="row"]', { hasText: "E2E Rail Contest" });
  const refresh = (page) => page.locator('[data-proof-of-reserves-target="refresh"]');

  test("Refresh is disabled while the first read runs, and a press straight after it reads again", async ({ page }) => {
    const chain = await fakeChain(page);
    await page.goto("/proof-of-reserves");
    await expect(refresh(page)).toBeDisabled();
    await expect(page.locator('[data-proof-of-reserves-target="busy"]')).toBeVisible();
    await expect(page.locator('[data-proof-of-reserves-target="idle"]')).toBeHidden();
    await expect(row(page).locator('[data-field="status"]')).toHaveText("Loading…");

    chain.release();
    await expect(page.locator('[data-proof-of-reserves-target="label"]')).toHaveText("Solvent");
    await expect(page.locator('[data-proof-of-reserves-target="label"]')).toHaveClass(/text-mint/);
    await expect(row(page).locator('[data-field="status"]')).toHaveText("Open");
    await expect(row(page).locator('[data-field="seasonId"]')).toHaveText("7");
    await expect(row(page).locator('[data-field="prizePool"]')).toHaveText("$150.00");
    await expect(row(page).locator('[data-field="poolNote"]')).toHaveText("Funds the guaranteed prize");
    await expect(row(page).locator('[data-field="prizes"]')).toHaveText("$150.00");
    await expect(row(page).locator('[data-field="currentEntries"]')).toHaveText("12");
    await expect(row(page).locator('[data-field="maxEntries"]')).toHaveText("30");
    await expect(row(page).locator('[data-field="entryFee"]')).toHaveText("$19.00");
    await expect(row(page).locator('[data-field="payoutList"]')).toHaveText(/1st\s*\$100\.00\s*2nd\s*\$50\.00/);
    await expect(row(page).locator('[data-field="loading"]')).toBeHidden();
    await expect(page.locator('[data-proof-of-reserves-target="fetched"]')).toBeVisible();

    const before = chain.reads;
    await refresh(page).click();
    await expect.poll(() => chain.reads).toBeGreaterThan(before);
    await expect(refresh(page)).toBeEnabled();
  });

  test("a press straight after a Turbo visit reads again", async ({ page }) => {
    const chain = await fakeChain(page);
    chain.release();
    await page.goto("/help");
    await turboVisit(page, "/proof-of-reserves", '[data-controller="proof-of-reserves"]');
    await refresh(page).click();
    await expect.poll(() => chain.reads).toBeGreaterThanOrEqual(2 * (await page.locator('[data-proof-of-reserves-target="row"]').count()));
    await expect(row(page).locator('[data-field="status"]')).toHaveText("Open");
  });
});
