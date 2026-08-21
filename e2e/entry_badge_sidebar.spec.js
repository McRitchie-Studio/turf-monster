const { test, expect } = require("@playwright/test");
const { login } = require("./helpers");

// The navbar ✨ entry-token badge, in a browser.
//
// WHY THESE LIVE HERE AND NOT IN A RENDER TEST. Every tier the `ui-only` shape
// demands renders to a String, and all three things this file covers are
// invisible in the response bytes:
//   · the CONTACT SHADOW is a computed box-shadow painting onto the avatar. The
//     stylesheet read correct while it painted NOTHING — the knob that carries
//     it tied .legendary-badge on specificity and lost on source order, so it
//     resolved to the treatment's transparent default. A markup assertion could
//     not have seen that, and neither could a class-list one.
//   · CLICKING THE BADGE opens the settings sidebar — and it has to still be
//     open a beat later, because the panel closes on @click.outside and the
//     badge sits outside it. Markup cannot tell an open panel from one that
//     opened and shut in the same tick.
//   · the SIDEBAR CHIP tracks the live count through a window event, and it
//     mounts TWICE (the sidebar body renders into the desktop and the mobile
//     panel). Server markup shows the load-time number in both; only a browser
//     shows whether an update reaches them.
//
// The seeded e2e user holds ZERO entry tokens, so the badge and the chip both
// start hidden and are surfaced the way the app surfaces them — through
// updateNavTokens(), the same call the mint and consume paths make.

const BADGE = "[data-free-entry-badge]";
const CHIP = "[data-free-entry-chip]";

async function signInWithBadge(page) {
  await page.setViewportSize({ width: 1366, height: 800 });
  await login(page, "alex@mcritchie.studio", "password");
  await page.goto("/contests");
  await expect(page.locator(BADGE).first()).toBeAttached();
  // QUIESCE. refreshBalance/refreshSession land on their own schedule and
  // rewrite the balance slot right beside the badge; settle before measuring.
  await page.waitForTimeout(4000);
  await page.evaluate(() => window.updateNavTokens(1));
  await expect(page.locator(BADGE).first()).toBeVisible();
}

test("the badge casts a dark contact shadow onto the avatar", async ({ page }) => {
  test.setTimeout(60_000);
  await signInWithBadge(page);

  // FREEZE THE PAN FIRST. `reducedMotion: "reduce"` in playwright.config.js does
  // NOT reach the page (see the note there), so .legendary-badge animates its
  // gradient forever and a naive pixel diff of this disc differs every frame —
  // which would make the comparison below pass no matter what the CSS does.
  // emulateMedia genuinely flips the query, and the treatment's own
  // prefers-reduced-motion rule stops the animation.
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.waitForTimeout(500);

  // Declared: the dark shadow must LEAD the stack. Behind the white bloom it is
  // washed out, so order is part of the claim, not formatting.
  const shadow = await page.evaluate((sel) =>
    getComputedStyle(document.querySelector(sel)).boxShadow, BADGE);
  expect(shadow, "the contact shadow must resolve dark, not to the transparent default")
    .toMatch(/^rgba\(0, 0, 0, 0\.55\) 2px 3px 5px/);

  // Painted: a strip over the AVATAR, just past the disc's lower-right edge —
  // where the shadow falls and where the disc's own gradient cannot reach.
  const box = await page.evaluate((sel) => {
    const r = document.querySelector(sel).getBoundingClientRect();
    return { x: r.x, y: r.y, w: r.width, h: r.height };
  }, BADGE);
  const clip = {
    x: Math.round(box.x + box.w - 2),
    y: Math.round(box.y + box.h - 2),
    width: 10,
    height: 10,
  };
  const sample = async () => (await page.screenshot({ clip })).toString("base64");

  // PROBE STABILITY. If the strip moves on its own, "differs" means nothing.
  const before = await sample();
  await page.waitForTimeout(600);
  expect(await sample(), "the probe strip must be still before it is used to judge a change")
    .toBe(before);

  // Neutralise ONLY the knob — the treatment keeps its rim, bloom and gradient,
  // so anything that changes here is the contact shadow and nothing else.
  await page.evaluate((sel) => {
    document.querySelector(sel).style.setProperty("--lb-contact", "0 0 0 0 rgba(0, 0, 0, 0)");
  }, BADGE);
  await page.waitForTimeout(200);
  expect(await sample(), "with the knob neutralised those pixels must change — otherwise the shadow was never painting")
    .not.toBe(before);
});

test("clicking the badge opens the settings sidebar and it stays open", async ({ page }) => {
  test.setTimeout(60_000);
  await signInWithBadge(page);

  const panel = page.locator("#gear-sidebar");
  await expect(panel).toBeHidden();

  await page.locator(BADGE).first().click();
  await expect(panel).toBeVisible();

  // It must STILL be open a beat later. The panel closes on @click.outside and
  // the badge sits outside it, so this is the shape of failure to watch for:
  // open-then-immediately-shut, which a toBeVisible() fired straight after the
  // click can still catch mid-flight.
  //
  // MEASURED, so the comment does not overclaim: dropping .stop from the badge
  // does NOT reproduce it. Alpine's outside handler skips a target that was not
  // visible when the listener ran, and the panel is still hidden at that instant.
  // .stop stays because the avatar and username beside it carry it and a
  // document-level delegated handler in the layout reads that same click — but
  // this spec's evidence is "the panel opens and stays open", not a claim about
  // which modifier holds it there.
  await page.waitForTimeout(800);
  await expect(panel, "the panel must still be open a beat after the click that opened it")
    .toBeVisible();
});

test("the sidebar chip tracks the live count in both panels", async ({ page }) => {
  test.setTimeout(60_000);
  await signInWithBadge(page);
  await page.locator(BADGE).first().click();
  await expect(page.locator("#gear-sidebar")).toBeVisible();

  // Read every mount, not the first. The desktop panel is the visible one at
  // this width and the mobile panel is display:none, but both chips are in the
  // DOM and both must follow the count — a querySelector-based sync would
  // update one and strand the other, and looking only at the visible one is
  // exactly how that ships green.
  const chips = () => page.evaluate((sel) =>
    Array.from(document.querySelectorAll(sel)).map((el) => ({
      text: el.textContent.replace(/\s+/g, " ").trim(),
      display: el.style.display,
    })), CHIP);

  expect((await chips()).length, "the sidebar body renders into both panels").toBe(2);

  await page.evaluate(() => window.updateNavTokens(5));
  await page.waitForTimeout(250);
  for (const chip of await chips()) {
    expect(chip.text).toBe("✨ 5 Free Entries");
    expect(chip.display).not.toBe("none");
  }

  // Singular. "5 Free Entrys" is what a bare plural suffix produces, and the
  // markup carries both spellings, so only a real count of 1 tells them apart.
  await page.evaluate(() => window.updateNavTokens(1));
  await page.waitForTimeout(250);
  for (const chip of await chips()) expect(chip.text).toBe("✨ 1 Free Entry");

  // Spent the last one: the chip must not keep promising an entry the user no
  // longer holds — the same failure the ✨ badge itself shipped with.
  await page.evaluate(() => window.updateNavTokens(0));
  await page.waitForTimeout(250);
  for (const chip of await chips()) expect(chip.display).toBe("none");
});
