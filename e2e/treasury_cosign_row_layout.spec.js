const { test, expect } = require("@playwright/test");

// [component] The treasury's cosign row keeps its Co-sign button on screen at a
// phone width, and stays one aligned control group on a desktop.
//
// THE DEFECT, MEASURED ON A GOVERNANCE BOOT AT 390px (2026-09-16). The row was
// two flex columns: the title column `flex-1 min-w-0`, the controls column
// `flex-shrink-0`. A column that may not shrink is as wide as its widest
// unwrapped line, and the signing roster's footer sentence is 528px on one line.
// So the controls column came out 550px inside a 294px card: the title column
// collapsed to 0px (the title stacked one word per line), and the Co-sign button
// ran from x=65 to x=615 on a 390px screen. Even with the roster hidden, the
// select's one-line label held the column at 283px and the title still got 0px.
// The select's fixed w-56 was NOT a driver: widening it changed nothing.
//
// WHY A BROWSER IS THE ONLY WITNESS. Every class in that row resolved, the page
// returned 200, and the markup read correctly. Overflow is what the layout
// engine does with the markup, and no server-side tier runs one. A test that
// asserted class strings would have passed on the broken row.
//
// WHY A HARNESS. The overflowing controls render only on a governance boot,
// which this lane is not (see TestController#treasury_layout_harness). The
// harness renders the REAL index template with two answers stubbed per row, so
// every box measured below is the page's own markup.

const HARNESS = "/test/treasury_layout_harness";
const PHONE = { width: 390, height: 844 };
// The widest width the row still stacks at. Beside a 320px column here the title
// column was about 200px, so the stacking breakpoint sits above it.
const NARROW_TABLET = { width: 640, height: 900 };
const DESKTOP = { width: 1280, height: 900 };

// Geometry of every row, read in one pass so the numbers agree with each other.
// The row checks below are SOFT so a red run names every broken box at once,
// not only the first; the test still fails on any of them.
async function rowGeometry(page) {
  return page.evaluate(() => {
    const box = (el) => {
      if (!el) return null;
      const r = el.getBoundingClientRect();
      return { left: r.left, right: r.right, top: r.top, width: r.width };
    };
    // Lines a block of text actually occupies: distinct line-box tops across its
    // text, so a title squeezed to one word per line reads as many lines.
    const lineCount = (el) => {
      const range = document.createRange();
      range.selectNodeContents(el);
      const tops = new Set([...range.getClientRects()].filter((r) => r.width > 0).map((r) => Math.round(r.top)));
      return tops.size;
    };

    const viewport = document.documentElement.clientWidth;
    const rows = [...document.querySelectorAll("[data-cosign-controls]")].map((controls) => {
      const card = controls.closest(".card");
      const style = getComputedStyle(card);
      const cardContent = card.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
      const title = card.querySelector("p.text-heading");
      const button = controls.querySelector("button[data-desktop-only-action]");
      let hit = null;
      if (button) {
        button.scrollIntoView({ block: "center", inline: "nearest" });
        const r = button.getBoundingClientRect();
        const at = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
        hit = !!at && button.contains(at);
      }
      // The rightmost edge any painted box in the card reaches. A 44-character
      // base58 address is one unbreakable word, and it spilled past the card.
      const contentRight = card.getBoundingClientRect().right - card.clientLeft - parseFloat(style.paddingRight);
      const widest = Math.max(...[...card.querySelectorAll("*")].map((el) => el.getBoundingClientRect())
        .filter((r) => r.width > 1 && r.height > 1).map((r) => r.right));
      return {
        slug: card.querySelector(".font-mono").textContent.trim(),
        cardContent,
        spill: widest - contentRight,
        title: box(title),
        titleWords: title.textContent.trim().split(/\s+/).length,
        titleLines: lineCount(title),
        controls: box(controls),
        // What the operator reads as the group: the select itself (not its label,
        // which stretches whatever the select does), the roster, the notes, and
        // the buttons.
        parts: [...controls.querySelectorAll("select, :scope > [data-signer-roster], :scope > p, :scope > button, :scope > form")].map(box),
        button: box(button),
        buttonHit: hit,
      };
    });
    window.scrollTo(0, 0);
    return { viewport, documentWidth: document.documentElement.scrollWidth, rows };
  });
}

async function setTheme(page, theme) {
  await page.addInitScript((t) => {
    try { localStorage.setItem("theme", t); } catch (_) {}
  }, theme);
}

function expectPhoneRow(row, viewport) {
  const where = `${row.slug} at ${viewport}px`;
  // The title keeps the card's width, so it wraps by phrase, not by word.
  expect.soft(row.title.width, `${where}: title column starved`).toBeGreaterThanOrEqual(row.cardContent * 0.9);
  expect.soft(row.titleLines, `${where}: title stacked one word per line`).toBeLessThan(row.titleWords);
  expect.soft(row.spill, `${where}: something in the row runs past the card`).toBeLessThanOrEqual(1);
  if (!row.button) return;
  // The whole button is on screen, and a tap at its centre lands on it.
  expect.soft(row.button.left, `${where}: Co-sign starts off screen`).toBeGreaterThanOrEqual(0);
  expect.soft(row.button.right, `${where}: Co-sign runs past the viewport edge`).toBeLessThanOrEqual(viewport);
  expect.soft(row.buttonHit, `${where}: a tap at Co-sign's centre lands elsewhere`).toBe(true);
}

async function assertPhoneLayout(page) {
  const g = await rowGeometry(page);
  // Rows that cannot co-sign carry no button; the two governance rows must.
  expect(g.rows.filter((r) => r.button).length, "harness lost its cosign rows").toBe(2);
  expect.soft(g.documentWidth, "the page scrolls sideways").toBeLessThanOrEqual(g.viewport);
  for (const row of g.rows) expectPhoneRow(row, g.viewport);
}

// PIN THE TRANSITION, NOT THE DESTINATION. The sentinel dies with the document,
// so its survival proves the arrival really was a Turbo visit and not a quiet
// full load that re-tests the direct path.
async function turboVisit(page, path) {
  await page.evaluate(() => { window.__sameDocument = true; });
  await page.evaluate((p) => window.Turbo.visit(p), path);
  await page.waitForFunction((p) => location.pathname === p && document.querySelectorAll("[data-cosign-controls]").length === 3, path);
  expect(await page.evaluate(() => window.__sameDocument)).toBe(true);
}

test.describe("treasury cosign row layout", () => {
  test("at 390px and 640px the Co-sign button stays on screen in both themes and both arrivals", async ({ page }) => {
    await page.setViewportSize(PHONE);

    for (const theme of ["light", "dark"]) {
      await setTheme(page, theme);
      await page.goto(HARNESS);
      const html = expect(page.locator("html"));
      await (theme === "dark" ? html.toHaveClass(/\bdark\b/) : html.not.toHaveClass(/\bdark\b/));
      await assertPhoneLayout(page);
    }

    // The second arrival: a Turbo Drive visit from another page.
    await page.goto("/contests");
    await turboVisit(page, HARNESS);
    await assertPhoneLayout(page);

    // The top of the stacked band.
    await page.setViewportSize(NARROW_TABLET);
    await page.goto(HARNESS);
    await assertPhoneLayout(page);
  });

  test("at 1280px the controls sit beside the title as one aligned group", async ({ page }) => {
    await page.setViewportSize(DESKTOP);
    await page.goto(HARNESS);

    const g = await rowGeometry(page);
    expect.soft(g.documentWidth).toBeLessThanOrEqual(g.viewport);

    for (const row of g.rows) {
      const where = `${row.slug} at ${g.viewport}px`;
      // Beside, not below: the controls start right of the title, on its top line.
      expect.soft(row.controls.left, `${where}: controls wrapped under the title`).toBeGreaterThan(row.title.right);
      expect.soft(Math.abs(row.controls.top - row.title.top), `${where}: controls not level with the row`).toBeLessThan(40);
      // The title keeps most of the row rather than yielding it to the controls.
      expect.soft(row.title.width, `${where}: title column starved`).toBeGreaterThanOrEqual(row.cardContent * 0.5);
      // One group: select, roster and button share the column's two edges.
      for (const part of row.parts) {
        expect.soft(Math.abs(part.left - row.controls.left), `${where}: a control is indented`).toBeLessThanOrEqual(1);
        expect.soft(Math.abs(part.right - row.controls.right), `${where}: a control is ragged on the right`).toBeLessThanOrEqual(1);
      }
      if (row.button) expect.soft(row.buttonHit, `${where}: a click at Co-sign's centre lands elsewhere`).toBe(true);
    }
  });
});
