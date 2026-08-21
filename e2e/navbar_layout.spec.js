const { test, expect } = require("@playwright/test");
const { login } = require("./helpers");

const VIEWPORTS = [
  { width: 1366, height: 800 },
  { width: 1024, height: 768 },
  { width: 820, height: 768 },
];

async function exposeStressControls(page) {
  await page.evaluate(() => {
    const badge = document.querySelector("[data-free-entry-badge]");
    if (badge) {
      badge.classList.remove("hidden");
      badge.dataset.tokenCount = "1";
    }

    const balance = document.querySelector("[data-balance-display]");
    if (balance) {
      balance.classList.remove("hidden");
      balance.textContent = "$1504";
    }
    // The balance slot's other face: a seeded $0-with-token user renders the
    // "✨ Free Entry" label ACTIVE instead of the amount. Stand it down so the
    // stress state is exactly one face — the widest amount — not both at once.
    const feLabel = document.querySelector("[data-free-entry-label]");
    if (feLabel) feLabel.classList.remove("is-active");
  });
}

async function navbarMetrics(page) {
  return await page.evaluate(() => {
    const viewportWidth = document.documentElement.clientWidth;
    const documentWidth = Math.max(
      document.documentElement.scrollWidth,
      document.body.scrollWidth
    );
    const navbar = document.querySelector("[data-navbar-root]");
    const visible = (element) => {
      const style = window.getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return style.display !== "none" &&
        style.visibility !== "hidden" &&
        rect.width > 0 &&
        rect.height > 0;
    };

    const selectors = [
      ["balance", "[data-balance-display]"],
      // The balance slot's OTHER face. Listed so the offscreen check covers it
      // too; in the amount state it rests at `visibility: hidden` and visible()
      // filters it right back out, so the amount pass measures exactly as before.
      ["freeEntry", "[data-free-entry-label]"],
      ["entry", "[data-free-entry-badge]"],
      ["username", "[data-username-display]"],
      ["profile", "[data-profile-image-toggle]"],
    ];

    const controls = selectors.flatMap(([name, selector]) =>
      Array.from(document.querySelectorAll(selector))
        .filter(visible)
        .map((element) => {
          const rect = element.getBoundingClientRect();
          return {
            name,
            text: element.textContent.trim().replace(/\s+/g, " "),
            left: rect.left,
            right: rect.right,
            width: rect.width,
            height: rect.height,
          };
        })
    );

    const navbarRect = navbar ? navbar.getBoundingClientRect() : null;
    const offscreen = controls.filter((control) =>
      control.left < -1 || control.right > viewportWidth + 1
    );

    return {
      viewportWidth,
      documentOverflow: documentWidth - viewportWidth,
      navbar: navbarRect && {
        left: navbarRect.left,
        right: navbarRect.right,
        width: navbarRect.width,
      },
      controls,
      offscreen,
    };
  });
}

async function expectNavbarContained(page) {
  const metrics = await navbarMetrics(page);
  const message = JSON.stringify(metrics, null, 2);

  expect(metrics.documentOverflow, message).toBeLessThanOrEqual(1);
  expect(metrics.offscreen, message).toEqual([]);
  expect(metrics.controls.some((control) => control.name === "balance"), message).toBe(true);
  expect(metrics.controls.some((control) => control.name === "entry"), message).toBe(true);
  expect(metrics.controls.some((control) => control.name === "username"), message).toBe(true);
  expect(metrics.controls.some((control) => control.name === "profile"), message).toBe(true);
}

test("logged-in navbar controls stay contained with balance and entry badge", async ({ page }) => {
  await page.setViewportSize(VIEWPORTS[0]);
  await login(page, "alex@mcritchie.studio", "password");

  for (const viewport of VIEWPORTS) {
    await page.setViewportSize(viewport);
    await page.goto("/contests");
    await expect(page.locator("[data-username-display]").first()).toBeVisible();
    await exposeStressControls(page);
    await expectNavbarContained(page);
  }
});


// Put the balance slot into its OTHER face by running the APP'S OWN RULE rather
// than hand-poking `.is-active` on: a $0 amount plus a held token is precisely
// what applyBalanceSlotRule() swaps for "Free Entry", and driving it through the
// real function means this pass guards the rule as well as the layout.
async function exposeFreeEntryFace(page) {
  await page.evaluate(() => {
    const badge = document.querySelector("[data-free-entry-badge]");
    if (badge) {
      badge.classList.remove("hidden");
      badge.dataset.tokenCount = "1";
    }
    const balance = document.querySelector("[data-balance-display]");
    if (balance) {
      balance.classList.remove("hidden");
      balance.textContent = "$0";
    }
    window.applyBalanceSlotRule(1);
  });
}

// HOW MUCH OF THE NAME CAN ACTUALLY BE READ. The username button is
// overflow-hidden with a fade mask, so its width alone does not say whether a
// reader gets a name or a sliver -- measure the characters whose glyphs fit
// inside the clipped box, which is the thing a person experiences.
async function usernameLegibility(page) {
  return await page.evaluate(() => {
    const u = document.querySelector("[data-username-display]");
    const width = u.getBoundingClientRect().width;
    const full = u.textContent.trim();
    const probe = document.createElement("span");
    const cs = window.getComputedStyle(u);
    probe.style.cssText =
      `position:absolute;visibility:hidden;white-space:pre;font:${cs.font};letter-spacing:${cs.letterSpacing}`;
    document.body.appendChild(probe);
    let visibleChars = 0;
    for (let i = 1; i <= full.length; i++) {
      probe.textContent = full.slice(0, i);
      if (probe.getBoundingClientRect().width <= width) visibleChars = i; else break;
    }
    probe.remove();
    return { width, visibleChars, name: full, length: full.length };
  });
}

// THE SQUEEZE BAND. 768px is a cliff, not a slope: .user-nav-col stops growing
// there (its clamp floor holds until 24vw overtakes 16rem near 1067px) at the
// same moment the gear + theme toggle join the row, and the username is the only
// item in it that can shrink. 768 and 1024 are the band's ends; 1366 is past it
// and proves the fix left the roomy widths alone.
const FREE_ENTRY_VIEWPORTS = [
  { width: 1366, height: 800 },
  { width: 1024, height: 768 },
  { width: 900, height: 768 },
  { width: 820, height: 768 },
  { width: 768, height: 768 },
];

test("logged-in navbar keeps the Free Entry face contained and the username readable", async ({ page }) => {
  await page.setViewportSize(FREE_ENTRY_VIEWPORTS[0]);
  await login(page, "alex@mcritchie.studio", "password");

  for (const viewport of FREE_ENTRY_VIEWPORTS) {
    await page.setViewportSize(viewport);
    await page.goto("/contests");
    await expect(page.locator("[data-username-display]").first()).toBeVisible();
    await exposeFreeEntryFace(page);

    const metrics = await navbarMetrics(page);
    const message = `${viewport.width}px: ${JSON.stringify(metrics, null, 2)}`;

    // The containment guard the amount face already gets, now on the WIDER face.
    expect(metrics.documentOverflow, message).toBeLessThanOrEqual(1);
    expect(metrics.offscreen, message).toEqual([]);
    expect(metrics.controls.some((c) => c.name === "freeEntry"), message).toBe(true);
    expect(metrics.controls.some((c) => c.name === "entry"), message).toBe(true);
    expect(metrics.controls.some((c) => c.name === "username"), message).toBe(true);
    expect(metrics.controls.some((c) => c.name === "profile"), message).toBe(true);
    // The amount is the face that STOOD DOWN -- it must not be showing too.
    expect(metrics.controls.some((c) => c.name === "balance"), message).toBe(false);

    // ...and the part containment alone never noticed. The wider face used to
    // starve the username to 15.6px -- zero readable characters of "mcritchie"
    // at every width from 768 through 1024 -- while documentOverflow stayed 0
    // and nothing went offscreen, so the old pass called that a pass.
    const legible = await usernameLegibility(page);
    const want = Math.min(4, legible.length);
    expect(legible.visibleChars,
      `${viewport.width}px: username readable chars ${JSON.stringify(legible)}`)
      .toBeGreaterThanOrEqual(want);
  }
});

// THE LEVEL-UP GLOW MUST SURVIVE ITS OWN REPLAY.
//
// glowFreeEntryBadge() strips `.free-entry-glow` on a timer. A replay inside
// that window is the NORMAL path, not the rare one — the layout's level-up
// listener arms the glow at +900ms while a first-token badge has not been
// surfaced yet, and updateNavTokens() replays it the moment the count hydrate
// lands. Both land inside the 4.4s window, so an unheld timer from the first
// play cuts the second one short: MEASURED at 1340ms of a 4200ms animation,
// against 4201ms for a glow that plays alone.
//
// TWO INDEPENDENT WITNESSES, because each covers the other's blind spot:
//
//   PAINT — a screenshot of a strip just OUTSIDE the badge's left edge. It has
//     to be outside: .legendary-badge pans a gradient across the disc forever,
//     so any crop containing the disc differs from any other frame no matter
//     what the glow is doing, and an assertion built on one can never fail.
//     (Do NOT assume prefers-reduced-motion saves you here. This project sets
//     `use: { reducedMotion: "reduce" }` in playwright.config.js and it does NOT
//     reach the page — measured, `matchMedia("(prefers-reduced-motion: reduce)")
//     .matches` is false and legendary-pan reports playState "running". An
//     earlier cut of this spec trusted that setting, cropped the disc, and
//     passed against the unfixed code.) The glow is a box-shadow, so it paints
//     into the strip while the pan cannot reach it.
//
//   TIMELINE — the badge's own running animations via Element.getAnimations().
//     That is the object actually driving the paint, so it says whether the
//     glow is live and how far through it is, rather than whether a class name
//     happens to be present.
const GLOW_STRIP_MS = 4400;  // solana_utils.js GLOW_MS
const GLOW_PAINT_MS = 4200;  // .free-entry-glow — 1.4s x 3
const REPLAY_AFTER_MS = 2000;

test("a level-up glow replayed inside the window still plays its full length", async ({ page }) => {
  test.setTimeout(60_000); // ~14s of deliberate waiting, plus login and nav.
  await page.setViewportSize({ width: 1366, height: 800 });
  await login(page, "alex@mcritchie.studio", "password");
  await page.goto("/contests");
  await expect(page.locator("[data-free-entry-badge]").first()).toBeVisible();
  // QUIESCE. refreshBalance/refreshSession land on their own schedule and
  // rewrite the balance slot, which reflows the username right beside the badge
  // — inside the probe strip. Settle first or the strip moves for reasons that
  // have nothing to do with the glow.
  await page.waitForTimeout(4000);

  const box = await page.evaluate(() => {
    const b = document.querySelector("[data-free-entry-badge]");
    b.classList.remove("hidden");
    const r = b.getBoundingClientRect();
    return { x: r.x, y: r.y, w: r.width, h: r.height };
  });
  // 14px wide, ending 3px shy of the disc: inside the box-shadow's reach,
  // outside anything the gradient pan touches.
  const clip = {
    x: Math.max(0, Math.round(box.x - 17)),
    y: Math.max(0, Math.round(box.y - 6)),
    width: 14,
    height: Math.round(box.h + 12),
  };

  const sample = async () => ({
    shot: (await page.screenshot({ clip })).toString("base64"),
    glow: await page.evaluate(() => {
      const b = document.querySelector("[data-free-entry-badge]");
      const a = b.getAnimations().find((x) => x.animationName === "free-entry-glow");
      return a ? { state: a.playState, currentTime: Math.round(a.currentTime) } : null;
    }),
  });

  const resting = await sample();
  expect(resting.glow, "the badge must start with no glow running").toBe(null);

  // PROBE STABILITY. If the strip changes on its own while nothing is glowing,
  // then "differs from resting" means nothing later and every paint assertion
  // below would pass no matter what the code does. That is not hypothetical: an
  // earlier cut of this spec sampled before the page had settled, the username
  // reflowed inside the strip, and the paint witness went blind while still
  // reporting success. Fail HERE, loudly, rather than there, silently.
  await page.waitForTimeout(1000);
  const restingAgain = await sample();
  expect(restingAgain.shot,
    "the probe strip must be STABLE at rest, or it cannot witness the glow").toBe(resting.shot);

  const t0 = Date.now();
  await page.evaluate(() => window.glowFreeEntryBadge());

  // PROBE SELF-CHECK. If the strip cannot see a glow that is provably running,
  // every later paint assertion is worthless — fail here rather than there.
  const firstPlay = await sample();
  expect(firstPlay.glow, "the first play must start a free-entry-glow animation").not.toBe(null);
  expect(firstPlay.shot, "the strip must be able to SEE the glow").not.toBe(resting.shot);

  await page.waitForTimeout(Math.max(0, REPLAY_AFTER_MS - (Date.now() - t0)));
  await page.evaluate(() => window.glowFreeEntryBadge());
  const replayAt = Date.now() - t0;

  // 500ms PAST the first play's strip deadline. Its leftover timer used to fire
  // here and end a glow that had been running barely half its length.
  await page.waitForTimeout(Math.max(0, (GLOW_STRIP_MS + 500) - (Date.now() - t0)));
  const midReplay = await sample();
  const at = Date.now() - t0;
  const where = `t+${at}ms, replay fired at t+${replayAt}ms, glow=${JSON.stringify(midReplay.glow)}`;
  // PAINT first: it is the fact a person experiences. The timeline follows as
  // the mechanism that explains it.
  expect(midReplay.shot, `the replayed glow must still be PAINTING at ${where}`).not.toBe(resting.shot);
  expect(midReplay.glow, `the replayed glow must still be running at ${where}`).not.toBe(null);
  // ...and still be mid-animation, i.e. genuinely playing its full length rather
  // than merely existing.
  expect(midReplay.glow.currentTime,
    `the replayed glow must not have run past its own length at ${where}`)
    .toBeLessThan(GLOW_PAINT_MS);

  // ...and it must still END. A timer that is cleared but never re-armed would
  // leave the badge glowing forever — the opposite failure, equally wrong.
  await page.waitForTimeout(Math.max(0, (replayAt + GLOW_STRIP_MS + 900) - (Date.now() - t0)));
  const settled = await sample();
  expect(settled.glow, `the glow must have ended by t+${Date.now() - t0}ms`).toBe(null);
  expect(settled.shot, `the badge must be back at rest by t+${Date.now() - t0}ms`).toBe(resting.shot);
});
