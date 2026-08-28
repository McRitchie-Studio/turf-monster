const { test, expect } = require("@playwright/test");
const { reseed, allowMotion, loginAdmin, createActiveEntry } = require("./helpers");

// The league-wide live scoreboard at /live.
//
// What this proves that the Rails tests cannot: that a scoring event recorded
// on the SERVER reaches an already-open browser over the websocket, without a
// reload — the whole reason the page exists. The dev toolbar is the injector,
// standing in for a real NFL scoring play.
test.beforeEach(async ({ request }) => await reseed(request));

test.describe("Live NFL scoreboard", () => {
  test("renders the board without a sign-in", async ({ page }) => {
    await page.goto("/live");

    // Named, not `level: 1` — the navbar brand is also an h1, so an unnamed
    // level-1 lookup is a strict-mode violation rather than an assertion.
    await expect(page.getByRole("heading", { name: /Week 4/ })).toBeVisible();
    await expect(page.locator('[data-test="live-game-tile"]').first()).toBeVisible();
    // Public: no redirect to the sign-in screen.
    await expect(page).toHaveURL(/\/live$/);

    // THE KICKOFF FORMATTER MUST SETTLE. It rewrites <time> text from inside the
    // board's MutationObserver, and an unconditional write re-fires that
    // observer forever — which never wedges the main thread, so the server
    // still answers curl in milliseconds while the page never reaches `load`
    // and every spec here dies on a goto timeout. Counting rewrites over a
    // second is the cheapest thing that tells those two apart.
    const rewrites = await page.evaluate(() => new Promise((resolve) => {
      const el = document.querySelector('time[data-role="kickoff"]');
      if (!el) return resolve(0);
      let n = 0;
      new MutationObserver(() => { n += 1; }).observe(el, { childList: true, characterData: true, subtree: true });
      setTimeout(() => resolve(n), 1000);
    }));
    expect(rewrites).toBeLessThan(5);
  });

  test("a recorded score reaches an open page over the websocket", async ({ page }) => {
    await allowMotion(page);
    await page.goto("/live");

    // Pick the first team in the injector and read its CURRENT score off the
    // board, so the assertion is a delta rather than a hardcoded number.
    const select = page.locator('[data-test="dev-score-team"]');
    await expect(select).toBeVisible();
    const target = await select.locator("option").first().getAttribute("value");
    const [gameSlug, teamSlug] = target.split("|");

    const scoreCell = page
      .locator(`[data-game-slug="${gameSlug}"] [data-team-slug="${teamSlug}"] [data-role="score"]`);
    const before = parseInt((await scoreCell.textContent()).trim(), 10);

    await select.selectOption(target);
    await page.locator('[data-test="dev-score-touchdown"]').click();

    // NO reload anywhere in this test. If the score moves, the broadcast landed.
    await expect(scoreCell).toHaveText(String(before + 6), { timeout: 10000 });
  });

  test("a touchdown raises the scoring banner in the team's colors", async ({ page }) => {
    await allowMotion(page);
    await page.goto("/live");

    const select = page.locator('[data-test="dev-score-team"]');
    await select.selectOption({ index: 0 });
    await page.locator('[data-test="dev-score-touchdown"]').click();

    const banner = page.locator("#nfl-score-banner");
    await expect(banner).toBeVisible({ timeout: 10000 });
    await expect(page.locator("#nfl-score-label")).toHaveText("Touchdown");
    await expect(page.locator("#nfl-score-points")).toHaveText("+6");

    // The banner wears the scoring team's brand color, not a generic surface —
    // that is the point of reading Team#card_background into the feed node.
    const bg = await banner.evaluate((el) => getComputedStyle(el).backgroundColor);
    expect(bg).not.toBe("rgba(0, 0, 0, 0)");
    expect(bg).not.toBe("rgb(30, 41, 59)"); // the neutral used only for FINAL

    // A touchdown gets the TOUCHDOWN entrance, not a shared one. Asserted on the
    // class rather than on pixels because the whole point of five animations is
    // that they are five DIFFERENT ones, and a shared fallback would still look
    // fine in a screenshot.
    await expect(banner).toHaveClass(/nfl-b-td/);
  });

  test("the scoring team's row animates in its own colors and stays hot", async ({ page }) => {
    await allowMotion(page);
    await page.goto("/live");

    const select = page.locator('[data-test="dev-score-team"]');
    const target = await select.locator("option").first().getAttribute("value");
    const [gameSlug, teamSlug] = target.split("|");
    await select.selectOption(target);

    const row = page.locator(`[data-game-slug="${gameSlug}"] [data-team-slug="${teamSlug}"]`);
    // Both brand colours must reach the row: the field (washes, rail glow) and
    // the ink (the score). The ink is the fix for a score that rendered in a
    // team's near-black brand colour and vanished against the dark board.
    const field = await row.evaluate((el) => getComputedStyle(el).getPropertyValue("--nfl-team").trim());
    const ink = await row.evaluate((el) => getComputedStyle(el).getPropertyValue("--nfl-team-ink").trim());
    expect(field).toMatch(/^#/);
    expect(ink).toMatch(/^#/);
    expect(ink).not.toBe(field);

    await page.locator('[data-test="dev-score-field_goal"]').click();

    const score = row.locator('[data-role="score"]');
    // A field goal gets the FIELD GOAL score motion, and the number goes hot.
    await expect(score).toHaveClass(/nfl-s-fg/, { timeout: 10000 });
    await expect(score).toHaveClass(/nfl-score-hot/);

    // Hot means bold and in the team's ink — not the board's default grey. It
    // must OUTLIVE the banner, which is the whole reason the state is held in JS
    // and re-applied rather than left on a node the next broadcast replaces.
    await page.waitForTimeout(5000);
    const hot = await score.evaluate((el) => ({
      weight: getComputedStyle(el).fontWeight,
      color: getComputedStyle(el).color,
      still: el.classList.contains("nfl-score-hot")
    }));
    expect(hot.still).toBe(true);
    expect(Number(hot.weight)).toBeGreaterThanOrEqual(900);
    expect(hot.color).not.toBe("rgb(148, 163, 184)");
  });

  test("each scoring type is worth its own points", async ({ page }) => {
    await page.goto("/live");

    const select = page.locator('[data-test="dev-score-team"]');
    const target = await select.locator("option").first().getAttribute("value");
    const [gameSlug, teamSlug] = target.split("|");
    await select.selectOption(target);

    const scoreCell = page
      .locator(`[data-game-slug="${gameSlug}"] [data-team-slug="${teamSlug}"] [data-role="score"]`);
    const before = parseInt((await scoreCell.textContent()).trim(), 10);

    await page.locator('[data-test="dev-score-field_goal"]').click();
    await expect(scoreCell).toHaveText(String(before + 3), { timeout: 10000 });

    await page.locator('[data-test="dev-score-safety"]').click();
    await expect(scoreCell).toHaveText(String(before + 5), { timeout: 10000 });

    await page.locator('[data-test="dev-score-pat"]').click();
    await expect(scoreCell).toHaveText(String(before + 6), { timeout: 10000 });
  });

  // The glow's RESET rule, which is the whole reason its window is a stored
  // timer rather than a fresh setTimeout per score. Run against a shortened
  // window (window.NFL_GLOW_MS) so this proves the rule in seconds — at the
  // real 45s the only honest version of this test takes 90 seconds and would
  // not get written.
  test("a score rings the card, and a second score restarts the ring's timer", async ({ page }) => {
    await allowMotion(page);
    await page.addInitScript(() => { window.NFL_GLOW_MS = 2000; });
    await page.goto("/live");

    const select = page.locator('[data-test="dev-score-team"]');
    const target = await select.locator("option").first().getAttribute("value");
    const [gameSlug] = target.split("|");
    await select.selectOption(target);

    const opacity = () =>
      page.locator(`[data-game-slug="${gameSlug}"]`).evaluate((el) =>
        getComputedStyle(el).getPropertyValue("--studio-team-glow-opacity").trim());

    await page.locator('[data-test="dev-score-touchdown"]').click();
    await expect.poll(opacity, { timeout: 10000 }).toBe("1");

    // Past the window with no further score: dark again.
    await expect.poll(opacity, { timeout: 10000 }).toBe("0");

    // Now re-score BEFORE the window closes and step past the FIRST score's
    // expiry. A timer that stacked instead of resetting goes dark here.
    await page.locator('[data-test="dev-score-field_goal"]').click();
    await expect.poll(opacity, { timeout: 10000 }).toBe("1");
    await page.waitForTimeout(1400);
    await page.locator('[data-test="dev-score-field_goal"]').click();
    await page.waitForTimeout(900);
    expect(await opacity()).toBe("1");

    // And it still expires on the SECOND score's schedule.
    await expect.poll(opacity, { timeout: 10000 }).toBe("0");
  });

  test("concluding a game reveals the final graphic and marks the card FINAL", async ({ page }) => {
    await allowMotion(page);
    await page.goto("/live");

    const select = page.locator('[data-test="dev-score-team"]');
    const target = await select.locator("option").first().getAttribute("value");
    const [gameSlug] = target.split("|");
    await select.selectOption(target);

    await page.locator('[data-test="dev-score-conclude"]').click();

    // The FINAL banner is its own branch: neutral slate, chequered flag, no
    // points and no team name — every other banner carries all three.
    const banner = page.locator("#nfl-score-banner");
    await expect(banner).toBeVisible({ timeout: 10000 });
    await expect(page.locator("#nfl-score-label")).toHaveText("Final");
    await expect(page.locator("#nfl-score-emoji")).toHaveText("🏁");
    await expect(page.locator("#nfl-score-points")).toHaveText("");
    await expect(banner).toHaveClass(/nfl-b-final/);

    // And the card itself settles into its final state, no reload.
    await expect(page.locator(`[data-game-slug="${gameSlug}"]`)).toContainText("Final");
  });

  test("clearing a game takes its score back to zero", async ({ page }) => {
    await page.goto("/live");

    const select = page.locator('[data-test="dev-score-team"]');
    const target = await select.locator("option").first().getAttribute("value");
    const [gameSlug, teamSlug] = target.split("|");
    await select.selectOption(target);

    const scoreCell = page
      .locator(`[data-game-slug="${gameSlug}"] [data-team-slug="${teamSlug}"] [data-role="score"]`);
    await page.locator('[data-test="dev-score-touchdown"]').click();
    await expect(scoreCell).not.toHaveText("0", { timeout: 10000 });

    await page.locator('[data-test="dev-score-clear"]').click();
    await expect(scoreCell).toHaveText("0", { timeout: 10000 });
  });
});

// The CONTEST live page at /contests/:slug/live.
//
// Its sibling above proves a score reaches an open browser. This proves the
// half that only exists here: the reader chooses which game to watch, and that
// choice has to survive the score arriving.
//
// WHY THIS CANNOT BE A RAILS TEST. Every assertion below is about state no
// response body carries. Which of the sixteen focus tiles is visible is decided
// by Alpine after paint; the hot score, the glow and the "this entry is mine"
// post are put back onto broadcast-replaced markup by a MutationObserver; and
// the focus surviving a broadcast is only observable AFTER a websocket message
// has torn out and rebuilt the DOM the choice was made in. A String assertion
// sees the markup that arrives, never the markup the page ends up with.
// nfl-weeks-15-17, NOT the main world-cup-2026 fixture. These specs have to LOCK
// a contest to make its live page reachable at all, and locking the contest the
// rest of the lane enters would leak that state into every spec that runs after
// them. This one backs multi_week_contest.spec.js alone, and the afterEach below
// hands it back unlocked.
const CONTEST = "nfl-weeks-15-17";

// The live page refuses a contest that has not locked (Contest#live? is
// locked? && !settled?), and locked? is derived from starts_at. #lock is the
// real admin path — off-chain here, so it just moves starts_at.
async function setLock(page, slug, inSeconds) {
  await page.goto(`/contests/${slug}`);
  const status = await page.evaluate(async ([contestSlug, seconds]) => {
    const token = document.querySelector('meta[name="csrf-token"]');
    const res = await fetch(`/contests/${contestSlug}/lock`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": token ? token.content : "" },
      body: JSON.stringify({ in_seconds: seconds }),
    });
    return res.status;
  }, [slug, inSeconds]);
  expect(status).toBeLessThan(400);
}

// Lock it, then land on the live page and CHECK WE ARE STILL THERE. #live
// redirects a contest that has not locked, and a redirect would otherwise show
// up further down as "element(s) not found" — pointing at the assertions rather
// than at the premise that failed.
async function openLive(page, slug) {
  await setLock(page, slug, 0);
  await page.goto(`/contests/${slug}/live`);
  await expect(page).toHaveURL(new RegExp(`/contests/${slug}/live$`));
}

// Score a real Goal on a game the contest actually contains, through the same
// dev injector the league board uses — so the whole pipeline runs (recompute →
// matchups → re-score → websocket) rather than a broadcast being faked.
async function recordTouchdown(page, gameSlug, teamSlug) {
  const status = await page.evaluate(async ([game, team]) => {
    const token = document.querySelector('meta[name="csrf-token"]');
    const res = await fetch("/dev/live_scores/record", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": token ? token.content : "" },
      body: JSON.stringify({ game_slug: game, team_slug: team, scoring_type: "touchdown" }),
    });
    return res.status;
  }, [gameSlug, teamSlug]);
  expect(status).toBe(200);
}

test.describe("Contest live page", () => {
  // Hand the contest back OPEN. `lock` only moves starts_at, so pushing it an
  // hour out is the same door in the other direction — no test-only endpoint,
  // and the next spec finds the contest as the seed left it.
  test.afterEach(async ({ page }) => {
    await loginAdmin(page);
    await setLock(page, CONTEST, 3600);
  });

  test("the focused game follows the chip you click", async ({ page }) => {
    await loginAdmin(page);
    await openLive(page, CONTEST);

    const focusTiles = page.locator('[data-test="live-focus-game"]');
    await expect(focusTiles.first()).toBeAttached();

    // Every game is rendered into the panel and all but one is hidden. Alpine
    // owns which — nothing in the response says it.
    const visible = () => page.locator('[data-test="live-focus-game"]:visible');
    await expect(visible()).toHaveCount(1);
    const before = await visible().getAttribute("data-focus-slug");

    // Click a DIFFERENT chip and the panel follows it.
    const other = page
      .locator(`[data-test="live-game-chip"]:not([data-game-slug="${before}"])`)
      .first();
    const wanted = await other.getAttribute("data-game-slug");
    await other.click();

    await expect(visible()).toHaveCount(1);
    await expect(visible()).toHaveAttribute("data-focus-slug", wanted);
    // The strip agrees with the panel — one chip marked, and it is that one.
    await expect(page.locator(".tt-chip-focused").first())
      .toHaveAttribute("data-game-slug", wanted);
  });

  test("a score lights both renderings and does not steal your focus", async ({ page }) => {
    await allowMotion(page);
    await loginAdmin(page);
    await createActiveEntry(page, CONTEST);
    await openLive(page, CONTEST);

    // Watch a game the reader CHOSE, not the one the page opened on — the bug
    // this guards is the broadcast resetting that choice.
    const visible = () => page.locator('[data-test="live-focus-game"]:visible');
    const opened = await visible().getAttribute("data-focus-slug");
    const chosen = page
      .locator(`[data-test="live-game-chip"]:not([data-game-slug="${opened}"])`)
      .first();
    const gameSlug = await chosen.getAttribute("data-game-slug");
    await chosen.click();
    await expect(visible()).toHaveAttribute("data-focus-slug", gameSlug);

    const teamSlug = await page
      .locator(`[data-test="live-focus-game"]:visible [data-team-slug]`)
      .first()
      .getAttribute("data-team-slug");

    const chipScore = page.locator(
      `[data-test="live-game-chip"][data-game-slug="${gameSlug}"] [data-team-slug="${teamSlug}"] [data-role="score"]`
    ).first();
    const tileScore = page.locator(
      `[data-test="live-focus-game"] [data-game-slug="${gameSlug}"] [data-team-slug="${teamSlug}"] [data-role="score"]`
    ).first();
    await expect(chipScore).toHaveText("0");

    await recordTouchdown(page, gameSlug, teamSlug);

    await expect(chipScore).not.toHaveText("0", { timeout: 15000 });
    await expect(tileScore).not.toHaveText("0", { timeout: 15000 });

    // EVERY rendering of that score, not just the two named above.
    //
    // The strip CLONES its whole row to loop seamlessly, so a game the reader
    // can see is drawn two or three times: the chip, its clone, and the tile.
    // The page looks up all of them; a querySelector would light the first and
    // leave the rest grey — invisible until the carousel scrolled the cold copy
    // into view. Asserting only the first chip and the tile does not catch that,
    // which is exactly what an earlier cut of this spec failed to notice when
    // the lookup was deliberately broken to check the spec bites.
    const everyCopy = page.locator(
      `[data-game-slug="${gameSlug}"] [data-team-slug="${teamSlug}"] [data-role="score"]`
    );
    const copies = await everyCopy.count();
    expect(copies).toBeGreaterThan(1);
    for (let i = 0; i < copies; i += 1) {
      await expect(everyCopy.nth(i)).toHaveClass(/nfl-score-hot/);
      await expect(everyCopy.nth(i)).not.toHaveText("0");
    }

    // The choice survived the broadcast that replaced the strip AND the panel.
    await expect(visible()).toHaveCount(1);
    await expect(visible()).toHaveAttribute("data-focus-slug", gameSlug);

    // AND the viewer's own row is still marked. This one is only true if the
    // script re-applied it: the broadcast sends one payload to every subscriber,
    // so the server's re-render of the leaderboard cannot know whose entry it is.
    await expect(page.locator("[data-role=entry-row].tt-lb-mine")).toHaveCount(1);
  });
});
