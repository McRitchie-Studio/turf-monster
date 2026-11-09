const { test, expect, devices } = require("@playwright/test");
const { loginAdmin, reseed, motionSettled } = require("./helpers");

// [e2e] Turf on the engine's glass surfaces (/tasks/turf-adopts-glass-style).
//
// The server tier proves the attribute and the markup. Only a browser proves the
// paint: that the fill really is translucent, that the blur landed, and, for the
// hard line, that on the wallet and entry screens glass moves no control beyond the
// lit button's 1px border. The last one compares each control's box with the
// attribute on and off in one page, so it needs no stored numbers.

const CONTEST = "world-cup-2026";

const alpha = (color) => {
  const slash = color.match(/\/\s*([\d.]+)\s*\)/);
  if (slash) return parseFloat(slash[1]);
  const rgba = color.match(/^rgba\([^)]*,\s*([\d.]+)\)$/);
  return rgba ? parseFloat(rgba[1]) : 1;
};

// Every control in `scope`, with its box. Scoped to what a person can reach.
const controlBoxes = (page, scope) =>
  page.evaluate((selector) => {
    const root = document.querySelector(selector) || document;
    return [...root.querySelectorAll("button, a[href], input, select, textarea")]
      .filter((el) => el.getClientRects().length)
      .map((el) => {
        const r = el.getBoundingClientRect();
        return { text: (el.textContent || el.placeholder || "").trim().slice(0, 30), x: r.x, y: r.y, w: r.width, h: r.height };
      });
  }, scope);

const expectGlassMovesNothing = async (page, scope) => {
  const on = await controlBoxes(page, scope);
  expect(on.length, "the screen has controls to compare").toBeGreaterThan(0);
  await page.evaluate(() => document.documentElement.removeAttribute("data-surface-style"));
  const off = await controlBoxes(page, scope);
  await page.evaluate(() => document.documentElement.setAttribute("data-surface-style", "glass"));

  // The same controls, in the same order. The engine's lit button adds a clear 1px border, so a
  // filled button is up to 2px larger, and a stack of them pushes what follows it. No more than that.
  expect(on.map((c) => c.text)).toEqual(off.map((c) => c.text));
  on.forEach((box, i) => {
    const was = off[i];
    const where = `${box.text}: ${JSON.stringify(was)} -> ${JSON.stringify(box)}`;
    expect(Math.abs(box.w - was.w), where).toBeLessThanOrEqual(2);
    expect(Math.abs(box.h - was.h), where).toBeLessThanOrEqual(2);
    expect(Math.abs(box.x - was.x), where).toBeLessThanOrEqual(2);
    expect(Math.abs(box.y - was.y), where).toBeLessThanOrEqual(16);
  });
};

const openModal = (page, id, props = {}) =>
  page.evaluate(([modal, modalProps]) => window.Alpine.store("modals").open(modal, modalProps), [id, props]);

for (const [label, viewport] of [["desktop", { width: 1280, height: 900 }], ["phone", devices["iPhone 13"].viewport]]) {
  test.describe(`glass at ${label}`, () => {
    test.use({ viewport });
    test.beforeEach(async ({ request }) => await reseed(request));

    test("cards are translucent, the navbar blurs, and a filled button is lit", async ({ page }) => {
      await loginAdmin(page);
      await page.goto("/contests");

      await expect(page.locator("html")).toHaveAttribute("data-surface-style", "glass");

      const card = page.locator(".card, .card-hover").first();
      await expect(card).toBeVisible();
      expect(alpha(await card.evaluate((el) => getComputedStyle(el).backgroundColor))).toBeLessThan(1);

      const nav = await page.locator(".nav-shell").evaluate((el) => getComputedStyle(el).backdropFilter);
      expect(nav).toContain("blur");

      const lit = await page.locator(".btn-primary:visible").first().evaluate((el) => {
        const after = getComputedStyle(el, "::after");
        return { image: getComputedStyle(el).backgroundImage, inset: after.boxShadow };
      });
      expect(lit.image).toContain("linear-gradient");
      expect(lit.inset).toContain("inset");
    });

    test("a team card is glass, and picking it keeps its ring and glow", async ({ page }) => {
      await loginAdmin(page);
      await page.goto(`/contests/${CONTEST}`);
      await page.waitForLoadState("networkidle");

      const card = page.locator('[x-data*="selectionBoard"] button[role="checkbox"]:not([disabled])').first();
      await expect(card).toBeVisible();
      expect(alpha(await card.evaluate((el) => getComputedStyle(el).backgroundColor))).toBeLessThan(1);
      await expect(card).toHaveClass(/tm-team-card/);

      const overlay = page.locator("div.fixed.inset-0.z-20.cursor-pointer");
      if (await overlay.isVisible({ timeout: 300 }).catch(() => false)) await overlay.click();
      await card.click();
      await expect(card).toHaveAttribute("aria-checked", "true");
      await expect(card).toHaveClass(/matchup-selected/);
      // transition-all, so the ring and glow arrive over a moment.
      await expect.poll(() => card.evaluate((el) => getComputedStyle(el).outlineWidth)).toBe("3px");
      await expect.poll(() => card.evaluate((el) => getComputedStyle(el).boxShadow)).toContain("20px");
    });

    test("the gear sidebar is the engine's glass panel, and its rows still work", async ({ page }) => {
      await loginAdmin(page);
      await page.goto("/contests");
      await page.locator("[data-gear-sidebar-trigger]:visible").first().click();

      const shell = page.locator("[data-sidebar-glass-shell]:visible");
      await expect(shell).toHaveCount(1);
      expect(await shell.evaluate((el) => getComputedStyle(el).backdropFilter)).toContain("blur");

      const rows = shell.locator('nav > [role="group"] > :is(a, button)');
      expect(await rows.count()).toBeGreaterThan(4);
      for (const row of await rows.all()) {
        expect(await row.evaluate((el) => el.getBoundingClientRect().height)).toBe(44);
      }
      await expect(shell.locator("[data-sidebar-glass-foot] a[href='/logout']")).toBeVisible();

      // The quest line truncates in its own box, clear of the close button.
      const close = await shell.locator("[data-sidebar-panel-close]").boundingBox();
      const lead = await shell.locator("[data-sidebar-panel-lead]").boundingBox();
      expect(lead.x + lead.width).toBeLessThanOrEqual(close.x);

      await shell.locator("[data-sidebar-panel-close]").click();
      await expect(shell).toHaveCount(0);
    });

    test("the wallet modal stays solid, and glass moves none of its controls", async ({ page }) => {
      await loginAdmin(page);
      await page.goto(`/contests/${CONTEST}`);
      await page.waitForLoadState("networkidle");

      await openModal(page, "wallet-connect", { linkMode: false });
      const heading = page.getByText("Connect Wallet", { exact: true }).locator("visible=true").first();
      await expect(heading).toBeVisible();
      await expect(page.getByText("Phantom", { exact: true }).locator("visible=true").first()).toBeVisible();
      await motionSettled(page); // the mount spring has run out

      const modal = heading.locator("xpath=ancestor::*[contains(@class, 'rounded')][1]");
      const fill = await modal.evaluate((el) => {
        let node = el;
        while (node && alpha(getComputedStyle(node).backgroundColor) === 0) node = node.parentElement;
        function alpha(c) { const m = c.match(/,\s*([\d.]+)\)$|\/\s*([\d.]+)\s*\)/); return m ? parseFloat(m[1] || m[2]) : 1; }
        return getComputedStyle(node).backgroundColor;
      });
      expect(alpha(fill), "a modal floats over text, so it has no glass").toBe(1);
      await expectGlassMovesNothing(page, "body");
    });

    test("the entry slip keeps every control where it was", async ({ page }) => {
      await loginAdmin(page);
      await page.goto(`/contests/${CONTEST}`);
      await page.waitForLoadState("networkidle");

      const cards = page.locator('[x-data*="selectionBoard"] button[role="checkbox"]:not([disabled])');
      for (let i = 0; i < 6; i += 1) {
        const overlay = page.locator("div.fixed.inset-0.z-20.cursor-pointer");
        if (await overlay.isVisible({ timeout: 300 }).catch(() => false)) await overlay.click();
        await cards.nth(i).click();
        await expect(page.locator("body")).toContainText(`${i + 1} / 6`);
      }
      // The hold button only exists with a full cart. It is looked at, never held.
      await expect(page.locator(".hold-btn:visible").first()).toBeVisible();
      // THE BUTTON WIGGLES ON ITS OWN CLOCK. studio-engine's hold_button.js
      // NudgeCycle starts at page load (the button sits inside x-show, so its
      // controller connects while hidden), adds .nudge 3s in and .nudge-soft every
      // 10s after, and each one scales the button for 500ms. Its first nudge can
      // fire while the button is hidden and leave the class behind, so no class
      // or timing read can say where the next one falls. The wiggle is not glass
      // and not layout, so it is pinned still for the reads: with the button's
      // animations off, a nudge at any moment moves no box.
      await page.addStyleTag({ content: ".hold-btn, .hold-btn * { animation: none !important; }" });
      // Pointer off every control (a real move updates hover at once), then let
      // anything that started moving finish.
      await page.mouse.move(1, 1);
      await motionSettled(page);
      await expectGlassMovesNothing(page, "body");
    });
  });
}
