const { test, expect } = require("@playwright/test");
const { login, reseed } = require("./helpers");

// THE SCROLL-DRIVEN COLLAPSE on Turf's forked header (studio-engine 0.111.1,
// config.navbar_scroll_timeline; /tasks/turf-engine-navbar-timeline). From
// 768px the header keeps one height, its top band scrolls away with the page,
// and the logo and title shrink by transforms on the page's scroll timeline,
// so no script writes the header per frame and nothing relayouts. The
// component tier (test/integration/navbar_scroll_timeline_test.rb) proves the
// header opted in; only a browser can show the collapse is what the opt-in
// promises, and that the in-header bars stay on screen through it.
const PLAYER = "mason@mcritchie.studio";
const DESKTOP = { width: 1280, height: 800 };
const HEADER = "header[data-navbar-root]";

// The band the controller published against the header's own collapse. It is
// re-measured when the account column hydrates (app/javascript/nav_band_watch.js),
// so wait for the two to agree before reading anything.
async function settled(page) {
  const header = page.locator(HEADER);
  await expect(header).toHaveAttribute("data-nav-timeline-on", "");
  await page.evaluate(() => document.fonts.ready);
  // The account column hydrates after load (the balance reveals itself), and
  // the band is re-measured then; a reading taken before it would be stale.
  await page.waitForLoadState("networkidle");
  const read = () => header.evaluate((h) => {
    const band = parseFloat(h.style.getPropertyValue("--nav-band"));
    h.style.setProperty("--nav-p", "1");
    const collapsed = h.offsetHeight;
    h.style.removeProperty("--nav-p");
    return { band, rest: h.offsetHeight, collapsed };
  });
  await expect.poll(async () => { const m = await read(); return Math.abs(m.band - (m.rest - m.collapsed)); },
    { message: "--nav-band is the header's own collapse" }).toBeLessThanOrEqual(0.5);
  return read();
}

// Scrolls in small steps, then a flick, reading every frame: the header's box,
// the document's height, the in-header bars' top, and every inline style write
// the header took.
const flick = (page) => page.evaluate(async (sel) => {
  const h = document.querySelector(sel);
  const bars = h.querySelector("[data-nav-header-bars]");
  const frame = () => new Promise((r) => requestAnimationFrame(r));
  const writes = [];
  new MutationObserver((ms) => ms.forEach((m) => writes.push(`${Math.round(scrollY)}: ${m.oldValue} -> ${h.getAttribute("style")}`)))
    .observe(h, { attributes: true, attributeFilter: ["style"], attributeOldValue: true });
  const rows = [];
  const read = () => {
    const r = h.getBoundingClientRect();
    rows.push({ y: scrollY, box: r.height, top: r.top, bottom: r.bottom,
      docH: document.documentElement.scrollHeight, barsTop: bars ? bars.getBoundingClientRect().top : null });
  };
  read();
  for (const s of [10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 600, 900]) { window.scrollBy(0, s); await frame(); read(); }
  const collapsed = rows[rows.length - 1];
  window.scrollBy(0, -3000); await frame(); read();
  return { rows, collapsed, writes };
}, HEADER);

test.describe("Navbar scroll timeline", () => {
  test.beforeEach(async ({ request }) => await reseed(request));

  test("from 768px the header collapses on the scroll timeline: one box, no per-frame writes", async ({ page }) => {
    await page.setViewportSize(DESKTOP);
    await login(page, PLAYER);
    await page.goto("/contests");
    const measured = await settled(page);

    const run = await flick(page);
    expect(new Set(run.rows.map((r) => r.box)).size, "the header's box never changes height").toBe(1);
    expect(new Set(run.rows.map((r) => r.docH)).size, "the document never changes height").toBe(1);
    expect(run.writes, "inline style writes on the header during the scroll").toEqual([]);
    // Stuck, what shows is the compact bar: the collapsed height.
    expect(Math.abs(run.collapsed.bottom - measured.collapsed)).toBeLessThanOrEqual(1);

    // Nothing of the header takes the pointer below the bar.
    await page.evaluate(() => window.scrollTo(0, 1200));
    const below = await page.evaluate((sel) => {
      const bar = document.querySelector(sel).getBoundingClientRect();
      return [0.1, 0.5, 0.9].map((fx) => {
        const el = document.elementFromPoint(innerWidth * fx, bar.bottom + 4);
        return !!(el && el.closest(sel));
      });
    }, HEADER);
    expect(below, "the header takes the pointer under its bar").toEqual([false, false, false]);

    // The chat reaction picker's floor is the header's LIVE bottom at the top of the page, not its pinned edge.
    await page.goto("/contests/world-cup-2026");
    await settled(page);
    const picker = await page.evaluate((sel) => {
      const btn = Object.assign(document.createElement("button"), { style: "position:fixed;left:400px;top:230px;width:24px;height:24px" });
      document.body.appendChild(btn);
      window.openReactionPicker(btn);
      return { top: document.getElementById("chat-reaction-picker").getBoundingClientRect().top, header: document.querySelector(sel).getBoundingClientRect().bottom };
    }, HEADER);
    expect(picker.top, `the picker opens clear of the expanded header ${JSON.stringify(picker)}`).toBeGreaterThanOrEqual(picker.header);
  });

  test("a frozen player's bar stays on screen above the compact bar through the collapse", async ({ page }) => {
    await page.setViewportSize(DESKTOP);
    await login(page, PLAYER);
    await page.request.post("/test/set_frozen", { data: { frozen: "true" } });
    try {
      await page.goto("/contests");
      await expect(page.locator(`${HEADER} > [data-nav-header-bars] [data-frozen-banner]`)).toBeVisible();
      const measured = await settled(page);
      // The bars sit inside the header, so the band does not count them: they
      // are in the expanded and the collapsed reading alike.
      const barsH = await page.locator(`${HEADER} > [data-nav-header-bars]`).evaluate((b) => b.offsetHeight);
      expect(barsH).toBeGreaterThan(0);
      expect(measured.collapsed).toBeGreaterThan(barsH);

      const run = await flick(page);
      expect(run.writes).toEqual([]);
      // Once the header meets the top of the window the bars hold at it: they
      // never go above the window while the band scrolls away.
      const pinned = run.rows.filter((r) => r.top <= 0.5);
      expect(pinned.length).toBeGreaterThan(3);
      pinned.forEach((r) => expect(Math.abs(r.barsTop), JSON.stringify(r)).toBeLessThanOrEqual(1));

      // Collapsed: the bar is the bars plus the compact row, and the bars' own
      // content still takes the pointer.
      // A scroll timeline's animations update on the next frame, so read after two.
      await page.evaluate(async () => {
        window.scrollTo(0, 1200);
        for (let i = 0; i < 2; i++) await new Promise((r) => requestAnimationFrame(r));
      });
      const hit = await page.evaluate((sel) => {
        const banner = document.querySelector(`${sel} [data-frozen-banner]`).getBoundingClientRect();
        const el = document.elementFromPoint(banner.left + banner.width / 2, banner.top + banner.height / 2);
        const bars = document.querySelector(`${sel} > [data-nav-header-bars]`).getBoundingClientRect();
        const logo = document.querySelector(`${sel} .nav-logo`).getBoundingClientRect();
        return { onBanner: !!(el && el.closest("[data-nav-header-bars]")), barsTop: bars.top, barsBottom: bars.bottom,
          logoTop: logo.top, hitWhat: el ? el.tagName : null };
      }, HEADER);
      expect(hit.onBanner, `the bar is on top and takes the pointer ${JSON.stringify(hit)}`).toBe(true);
      expect(Math.abs(hit.barsTop), "the bars sit at the top of the window").toBeLessThanOrEqual(1);
      expect(hit.logoTop, "the compact row starts below the bars").toBeGreaterThanOrEqual(hit.barsBottom);
    } finally {
      await page.request.post("/test/set_frozen", { data: { frozen: "false" } });
    }
  });

  test("a phone keeps the --nav-p collapse, and widening while scrolled leaves the header on screen", async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 812 });
    await login(page, PLAYER);
    await page.goto("/contests");
    const header = page.locator(HEADER);
    await expect(header).toHaveAttribute("data-nav-timeline", "");
    await expect(header).not.toHaveAttribute("data-nav-timeline-on", /.*/);
    await page.evaluate(() => window.scrollTo(0, 600));
    await expect.poll(() => header.evaluate((h) => h.style.getPropertyValue("--nav-p"))).toBe("1.0000");
    expect(await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)).toBe(0);

    await page.setViewportSize({ width: 600, height: 812 });
    await page.evaluate(() => window.scrollTo(0, 900));
    await page.setViewportSize(DESKTOP);
    await expect(header).toHaveAttribute("data-nav-timeline-on", "");
    const measured = await settled(page);
    await expect.poll(() => header.evaluate((h) => Math.round(h.getBoundingClientRect().bottom)),
      { message: "the compact bar is on screen after the resize" }).toBe(measured.collapsed);
  });
});
