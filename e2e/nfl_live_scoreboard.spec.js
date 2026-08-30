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

// Same injector, with the scorer PINNED. The dev endpoint otherwise picks a
// plausible player off the scoring team's roster, which is right for a demo and
// wrong for a test: the e2e database carries the small offline athlete seed, so
// which player is available depends on which game the contest opened on. Naming
// one keeps the assertion about the card, not about the fixture.
async function recordTouchdownBy(page, gameSlug, teamSlug, scorerSlug) {
  const status = await page.evaluate(async ([game, team, scorer]) => {
    const token = document.querySelector('meta[name="csrf-token"]');
    const res = await fetch("/dev/live_scores/record", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": token ? token.content : "" },
      body: JSON.stringify({
        game_slug: game, team_slug: team, scoring_type: "touchdown", scorer_slug: scorer,
      }),
    });
    return res.status;
  }, [gameSlug, teamSlug, scorerSlug]);
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

    // The banner is raised from the same partial the league board uses, and it
    // carries the scoring type's own entrance — a touchdown arrives as a
    // touchdown. Asserted here rather than in a spec of its own so the lane's
    // executed set is unchanged.
    const banner = page.locator("#nfl-score-banner");
    await expect(banner).toBeVisible();
    await expect(banner).toHaveClass(/nfl-b-td/);
    await expect(page.locator("#nfl-score-label")).toHaveText(/touchdown/i);
  });

  // THE SCORER REVEAL. A touchdown on the focused game swaps its events rail for
  // a card naming who scored.
  //
  // Josh Allen is pinned because he is in db/seeds/nfl_athletes_demo.rb, the
  // offline set this lane seeds — see recordTouchdownBy above.
  test("a touchdown on the focused game reveals the scorer", async ({ page }) => {
    await allowMotion(page);
    await loginAdmin(page);
    await openLive(page, CONTEST);

    const visible = () => page.locator('[data-test="live-focus-game"]:visible');
    const gameSlug = await visible().getAttribute("data-focus-slug");
    const teamSlug = await page
      .locator('[data-test="live-focus-game"]:visible [data-team-slug]')
      .first()
      .getAttribute("data-team-slug");

    await recordTouchdownBy(page, gameSlug, teamSlug, "josh-allen");

    // The frame is what wears the state, so one class swaps both children and
    // they can never disagree about which is showing.
    // WAIT FOR THE RAIL TO EXIST FIRST. A game with no scores yet renders no
    // events frame — the first touchdown is what brings one into being, via the
    // broadcast that re-renders the panel. Asserting the class on a locator that
    // has not resolved yet spends the whole timeout on the wrong question.
    const frame = page.locator(
      `[data-focus-slug="${gameSlug}"] [data-role="event-feed-frame"]`
    );
    await expect(frame).toHaveCount(1, { timeout: 15000 });
    await expect(frame).toHaveClass(/tt-revealing/, { timeout: 15000 });

    // The card that is actually IN the window. Two panes exist so the next
    // event can be built off screen, and the one parked below is legitimately
    // filled with the same content after a settle — asserting on the first
    // match would sometimes read the parked copy.
    const card = frame.locator('[data-role="scorer-card"]:visible').first();
    await expect(card.locator('[data-role="scorer-headline"]')).toHaveText("Touchdown!");
    await expect(card.locator('[data-role="scorer-name"]')).toHaveText("Josh Allen");

    // The team leads the detail, above the player — a score belongs to a team
    // first. And the points chip is gone from the card entirely.
    await expect(card.locator('[data-role="scorer-mascot"]')).not.toHaveText("");
    await expect(card.locator('[data-role="scorer-points"]')).toHaveCount(0);

    // The card is genuinely on screen, not merely class-swapped: a transform
    // typo would leave it parked below the rail while the class said otherwise.
    //
    // toBeVisible() is not enough by itself — overflow clipping is not "hidden"
    // to playwright, so a pane sliced in half by a wrong wheel position still
    // passes it. Assert CONTAINMENT: nothing of the card clipped by its frame.
    await expect(card).toBeVisible();

    // POLLED, AND A MISSING CARD IS A FAILURE — NOT A PASS.
    //
    // This read once and returned -1 when no card was centred in the window.
    // `-1 <= 1` is true, so the exact condition it exists to catch — no card
    // where one should be — read as SUCCESS. Sampled every 10ms it returned -1
    // from t=11ms to t=94ms, and it fired inside that window most runs. The
    // sentinel is now larger than any real clip, so "no card" cannot satisfy it.
    await expect
      .poll(async () =>
        frame.evaluate((f) => {
          const w = f.getBoundingClientRect();
          const shown = [...f.querySelectorAll('[data-role="scorer-card"]')].find((c) => {
            const r = c.getBoundingClientRect();
            const mid = (r.top + r.bottom) / 2;
            return mid > w.top && mid < w.bottom;
          });
          if (!shown) return Number.MAX_SAFE_INTEGER;
          const r = shown.getBoundingClientRect();
          return Math.round(Math.max(0, w.top - r.top) + Math.max(0, r.bottom - w.bottom));
        })
      )
      .toBeLessThanOrEqual(1);
    await expect(card).toHaveAttribute("aria-hidden", "false");

    // AND THE LIST HAS LEFT THE WINDOW. Asserted on GEOMETRY, not opacity: the
    // panes do not fade any more, they ride a track that rolls, so the list is
    // gone because it is outside the frame's box — not because it went
    // transparent. An opacity assertion here passed against the old cross-fade
    // and reported nothing about the wheel.
    await expect
      .poll(async () =>
        frame.evaluate((f) => {
          const w = f.getBoundingClientRect();
          const feed = f.querySelector(".tt-event-feed").getBoundingClientRect();
          const overlap = Math.min(feed.bottom, w.bottom) - Math.max(feed.top, w.top);
          return Math.max(0, Math.round(overlap));
        })
      )
      .toBeLessThan(4);
  });

  // The card is a MOMENT, not a new resting state. It rides the banner chain,
  // so it retires when the chain drains and the rail goes back to its list.
  test("the scorer card retires and the events list returns", async ({ page }) => {
    await allowMotion(page);
    await loginAdmin(page);
    await openLive(page, CONTEST);

    const visible = () => page.locator('[data-test="live-focus-game"]:visible');
    const gameSlug = await visible().getAttribute("data-focus-slug");
    const teamSlug = await page
      .locator('[data-test="live-focus-game"]:visible [data-team-slug]')
      .first()
      .getAttribute("data-team-slug");

    await recordTouchdownBy(page, gameSlug, teamSlug, "josh-allen");

    // WAIT FOR THE RAIL TO EXIST FIRST. A game with no scores yet renders no
    // events frame — the first touchdown is what brings one into being, via the
    // broadcast that re-renders the panel. Asserting the class on a locator that
    // has not resolved yet spends the whole timeout on the wrong question.
    const frame = page.locator(
      `[data-focus-slug="${gameSlug}"] [data-role="event-feed-frame"]`
    );
    await expect(frame).toHaveCount(1, { timeout: 15000 });
    await expect(frame).toHaveClass(/tt-revealing/, { timeout: 15000 });

    // A lone banner holds 8s; the card goes with it. Waiting on the class rather
    // than on a timer keeps this honest if that hold is ever retuned.
    await expect(frame).not.toHaveClass(/tt-revealing/, { timeout: 20000 });
    await expect(frame.locator('[data-role="scorer-card"]').first()).toHaveAttribute("aria-hidden", "true");

    // THE LIST IS BACK IN THE WINDOW — measured as POSITION, not as content.
    //
    // The first version of this assertion divided the overlap by the FRAME's
    // height, which reduces to feedHeight / frameHeight: a count of scoring
    // rows, not a wheel position. The feed is centred in a pane that exactly
    // fills the frame, so when the wheel is home the overlap IS the feed's own
    // height — and 85% is only reachable once the list OVERFLOWS the rail, about
    // five rows. This spec records ONE touchdown and nothing clears goals
    // between runs, so every attempt added a row and the number climbed: it
    // failed 3/3 locally and went green on CI only at retry 2. A spec that
    // passes because it has been run before is worse than no spec, and merged
    // as-is it would have reddened the first playwright attempt for every PR
    // after it.
    //
    // What actually says "the wheel is home" is that NO PART of the feed is
    // clipped by the frame — absolute pixels, independent of how much has been
    // scored.
    await expect
      .poll(async () =>
        frame.evaluate((f) => {
          const w = f.getBoundingClientRect();
          const feed = f.querySelector(".tt-event-feed").getBoundingClientRect();
          return Math.round(
            Math.max(0, w.top - feed.top) + Math.max(0, feed.bottom - w.bottom)
          );
        })
      )
      .toBeLessThanOrEqual(1);

    // And the track is at its resting position — the feed fitting and the wheel
    // being home are only the same thing when the transform is zero.
    await expect
      .poll(async () =>
        frame.evaluate((f) => {
          const t = getComputedStyle(f.querySelector(".tt-event-track")).transform;
          if (t === "none") return 0;
          const m = t.match(/matrix\(([^)]+)\)/);
          return m ? Math.abs(Math.round(parseFloat(m[1].split(",")[5]))) : -1;
        })
      )
      .toBe(0);
  });

  // ── A HEADSHOT THAT FAILS SLOWLY ──────────────────────────────────────────
  //
  // The card and the banner both lead with a portrait, and both used to ask
  // "has this url not FAILED?" — a deny-list over a state that also holds
  // 'loading'. The presentation gate gives up after HEADSHOT_WAIT_MS and paints
  // anyway, so a failure slower than that arrived as 'loading', counted as
  // usable, and reproduced the symptom the fast case had already fixed.
  //
  // A FAST 404 was always handled — that is the point of routing this one SLOW.
  //
  // SAMPLED ACROSS THE WINDOW, not polled for the happy ending. An earlier cut
  // polled for "initials visible" with a long timeout and PASSED ON THE BUG: a
  // later broadcast repaints the card, by which time the preload has recorded
  // 'failed', so the system recovers on its own and the poll sees the recovery.
  // It proved "it eventually looks right", which was never in doubt. The defect
  // is a WINDOW, so the assertion is about the window — while the card is
  // revealed there must never be a frame showing neither picture nor initials.
  test("a headshot that fails slowly still shows initials and the points", async ({
    page,
  }) => {
    // The route hangs 12s on purpose, so this outlives the default budget.
    test.setTimeout(60000);
    await allowMotion(page);
    await loginAdmin(page);
    await openLive(page, CONTEST);

    // Longer than HEADSHOT_WAIT_MS (2s) plus imgReady's own 2s, so the event is
    // presented while the picture is still in flight.
    await page.route("**/headshots/**", async (route) => {
      await new Promise((r) => setTimeout(r, 12000));
      await route.abort("failed");
    });

    const visible = () => page.locator('[data-test="live-focus-game"]:visible');
    const gameSlug = await visible().getAttribute("data-focus-slug");
    const teamSlug = await page
      .locator('[data-test="live-focus-game"]:visible [data-team-slug]')
      .first()
      .getAttribute("data-team-slug");

    await recordTouchdownBy(page, gameSlug, teamSlug, "josh-allen");

    // THE MEASUREMENT IS A DURATION, NOT A FRAME.
    //
    // "Both hidden" happens legitimately for a frame or two: when the preload
    // already said 'ready', the card hides the initials and waits for its own
    // <img> to decode, which is a blink. Asserting on any single such frame
    // failed on the FIX as well as the bug — measured at 7ms in, with
    // complete:false, which is exactly that healthy blink.
    //
    // The defect is that the gap PERSISTS: with a deny-list read the card sat
    // showing nothing from the moment it painted until the next broadcast
    // repainted it — seconds, not milliseconds. So this measures the longest
    // continuous stretch with neither picture nor initials, and allows a blink.
    const gap = await page.evaluate(async (slug) => {
      const t0 = Date.now();
      const deadline = t0 + 14000;
      let sawRevealed = false;
      let longest = 0;
      let runStart = null;

      while (Date.now() < deadline) {
        const f = document.querySelector(
          `[data-focus-slug="${slug}"] [data-role="event-feed-frame"]`
        );
        let blank = false;

        if (f && f.classList.contains("tt-revealing")) {
          const w = f.getBoundingClientRect();
          const card = [...f.querySelectorAll('[data-role="scorer-card"]')].find((c) => {
            const r = c.getBoundingClientRect();
            const mid = (r.top + r.bottom) / 2;
            return mid > w.top && mid < w.bottom;
          });
          if (card) {
            sawRevealed = true;
            const img = card.querySelector('[data-role="scorer-headshot"]');
            const ini = card.querySelector('[data-role="scorer-initials"]');
            blank =
              (!img || img.classList.contains("hidden")) &&
              (!ini || ini.classList.contains("hidden"));
          }
        }

        const now = Date.now();
        if (blank) {
          if (runStart === null) runStart = now;
          longest = Math.max(longest, now - runStart);
        } else {
          runStart = null;
        }
        await new Promise((r) => setTimeout(r, 50));
      }
      return { sawRevealed, longest };
    }, gameSlug);

    expect(gap.sawRevealed, "the card never revealed — the test proved nothing").toBe(true);
    expect(
      gap.longest,
      `the card showed neither a picture nor initials for ${gap.longest}ms`
    ).toBeLessThan(1000);

    // THE BANNER: the points chip, not a broken image and a literal alt string.
    await expect(page.locator("#nfl-score-avatar")).toHaveClass(/hidden/);
    await expect(page.locator("#nfl-score-points")).toHaveText("+6");
  });


  // ── THE STRIP IS THE READER'S ────────────────────────────────────────────
  //
  // The markup test can see overflow-x and the handlers. What it cannot see is
  // the thing that actually broke before: the rotation and a reader's scroll
  // both trying to own the position. That was impossible to get wrong safely
  // while one drove `transform` and the other drove scrollLeft — whichever
  // wrote last snapped the strip out from under the other — so the fix made the
  // native scroll offset the only owner, and this is where that is proven.
  test("a reader can scroll the strip, and it stays where they put it", async ({
    page,
  }) => {
    test.setTimeout(90000);
    await allowMotion(page);
    await loginAdmin(page);
    await openLive(page, CONTEST);

    const viewport = page.locator('[x-ref="viewport"]').first();
    const at = () => viewport.evaluate((el) => Math.round(el.scrollLeft));

    // It has somewhere to scroll TO — otherwise the rest proves nothing.
    const room = await viewport.evaluate((el) => el.scrollWidth - el.clientWidth);
    expect(room, "the strip must overflow, or there is nothing to scroll").toBeGreaterThan(100);

    // The track carries no transform: scrollLeft is the sole owner of position.
    const transform = await viewport.evaluate(
      (el) => getComputedStyle(el.querySelector('[x-ref="track"]')).transform
    );
    expect(transform).toBe("none");

    // THE CONTROL, and it is the reason this test means anything.
    //
    // Everything below asserts the strip DID NOT move. That assertion is worth
    // nothing unless an untouched strip WOULD have moved in the same window —
    // and the rotation dwells 8s before its first frame, so a shorter wait
    // passes on a strip that is merely idle and on one that is properly stood
    // down alike. This measures the window first: leave the strip alone, wait
    // out the dwell, and prove it travels. Only then does "it held" have force.
    const restingAt = await at();
    await page.waitForTimeout(9500);
    const rotated = await at();
    expect(
      rotated - restingAt,
      "the rotation never moved, so a later 'it held' would prove nothing"
    ).toBeGreaterThan(30);

    // Now hand it over. A wheel stands the rotation down for good.
    //
    // Then WAIT FOR THE WHEEL TO LAND before parking the strip by hand. Chromium
    // animates a wheel scroll, so it is still travelling when mouse.wheel()
    // resolves; assigning scrollLeft into that animation gets overwritten by the
    // frames still to come, and the strip settles somewhere else entirely.
    await viewport.hover();
    await page.mouse.wheel(300, 0);
    await expect
      .poll(async () => {
        const a = await at();
        await page.waitForTimeout(120);
        return (await at()) - a;
      }, { message: "the wheel scroll never settled", timeout: 5000 })
      .toBe(0);

    await viewport.evaluate((el) => { el.scrollLeft = 700; });
    expect(await at()).toBe(700);

    // GET THE POINTER OFF THE STRIP, or this test proves nothing.
    //
    // The strip pauses under the pointer (@mouseenter="pause()"), so a hovering
    // mouse holds it still whether or not the stand-down works — an earlier cut
    // of this test asserted "it held" with the pointer parked on the strip and
    // passed happily against a standDown() neutered to a no-op. Moving away
    // fires @mouseleave="resume()", and resume() is exactly what refuses once
    // the reader has taken over. Now only a REAL stand-down keeps it here.
    await page.mouse.move(5, 5);

    // AND IT STAYS — across a window we have just proven is long enough for the
    // rotation to have moved it.
    await page.waitForTimeout(9500);
    const held = await at();
    expect(Math.abs(held - 700), `the strip drifted to ${held}`).toBeLessThan(20);

    // AND IT SURVIVES A SCORE, which is the case that actually broke.
    //
    // Contest::LiveBroadcast#replace_games swaps the innerHTML of the container
    // this component's x-data lives in, so every goal destroys and rebuilds the
    // carousel. Before the state was hoisted out of that container, the reader's
    // offset and their stand-down went back to 0/false on every touchdown — on
    // the page this feature exists for, on the event that page exists to show.
    const chip = page.locator('[data-test="live-game-chip"][data-game-slug]').first();
    const gameSlug = await chip.getAttribute("data-game-slug");
    const teamSlug = await chip.locator("[data-team-slug]").first().getAttribute("data-team-slug");

    const swapped = viewport.evaluate((el) => new Promise((res) => {
      const box = el.closest('[id$="_games"]');
      new MutationObserver(() => res(true)).observe(box, { childList: true, subtree: true });
    }));
    await recordTouchdown(page, gameSlug, teamSlug);
    await swapped;
    await page.waitForTimeout(1500);

    const afterScore = await page.locator('[x-ref="viewport"]').first()
      .evaluate((el) => Math.round(el.scrollLeft));
    expect(
      Math.abs(afterScore - 700),
      `the score reset the strip to ${afterScore} — the reader lost their place`
    ).toBeLessThan(20);

    // Still stood down afterwards: the rebuilt component inherited the handover,
    // so the rotation does not start up again under someone who is reading.
    await page.waitForTimeout(9500);
    const settled = await page.locator('[x-ref="viewport"]').first()
      .evaluate((el) => Math.round(el.scrollLeft));
    expect(
      Math.abs(settled - 700),
      `the rotation restarted after the score and crept to ${settled}`
    ).toBeLessThan(20);
  });

});
