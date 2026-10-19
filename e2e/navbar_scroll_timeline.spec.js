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

  // /tasks/turf-navbar-avatar-table-header. On the timeline nothing writes
  // --nav-p, so before this the avatar, name and level kept their rest size in
  // the compact bar, and the avatar sat at the window edge, 80px right of the
  // content at 1440. The account now scales as the hub's does (avatar 40 -> 32)
  // and the row stops at the page container.
  //
  // /tasks/turf-avatar-name-gap. The name sits the hub's 12px from the avatar
  // (the engine's --nav-gap, measured ink to ink on the hub at 1440, 1280 and
  // 1024: 12px at rest and compact), at rest, mid-collapse and compact. Before
  // it the column's 6px padding, the row's 8px gap and the avatar's 12px
  // margin stacked to 26px. Reduced motion snaps the collapse at the first
  // pixel, so the mid-collapse reading turns it back on.
  const HUB_NAME_GAP = 12;
  for (const width of [1440, 1280, 1024]) {
    test(`at ${width} the account shrinks with the bar and the avatar sits on the container's right edge`, async ({ page }) => {
      await page.emulateMedia({ reducedMotion: "no-preference" });
      await page.setViewportSize({ width, height: 800 });
      await login(page, PLAYER);
      await page.goto("/contests");
      await settled(page);
      const read = () => page.evaluate(async (sel) => {
        for (let i = 0; i < 2; i++) await new Promise((r) => requestAnimationFrame(r));
        const h = document.querySelector(sel);
        const avatar = h.querySelector("[data-profile-image-toggle] > *").getBoundingClientRect();
        const column = h.querySelector(".user-nav-col .flex-1").getBoundingClientRect();
        const username = h.querySelector(".nav-username");
        const name = username.getBoundingClientRect();
        const ink = document.createRange();
        ink.selectNodeContents(username);
        const content = document.querySelector("body > .max-w-7xl");
        const box = content.getBoundingClientRect();
        const contentRight = box.right - parseFloat(getComputedStyle(content).paddingRight);
        return { y: Math.round(scrollY), avatar: avatar.height, avatarRight: avatar.right, contentRight, name: name.height,
          gap: avatar.left - column.right, nameGap: avatar.left - ink.getBoundingClientRect().right,
          clipped: username.scrollWidth > username.clientWidth + 0.5 };
      }, HEADER);
      const top = await read();
      const ramp = await page.locator(HEADER).evaluate((h) => {
        const css = getComputedStyle(h);
        return { start: parseFloat(css.getPropertyValue("--nav-start")) || 0, ramp: parseFloat(css.getPropertyValue("--nav-ramp")) };
      });
      await page.evaluate((y) => window.scrollTo(0, y), Math.round(ramp.start + ramp.ramp / 2));
      const mid = await read();
      await page.evaluate(() => window.scrollTo(0, 1200));
      const compact = await read();
      const both = JSON.stringify({ top, mid, compact });

      expect(mid.avatar, `mid-collapse is between the two sizes ${both}`).toBeLessThan(39.5);
      expect(mid.avatar, `mid-collapse is between the two sizes ${both}`).toBeGreaterThan(32.5);
      for (const at of [top, mid, compact]) {
        expect(Math.abs(at.nameGap - HUB_NAME_GAP), `the name sits the hub's ${HUB_NAME_GAP}px from the avatar ${both}`).toBeLessThanOrEqual(1);
        expect(at.clipped, `the name is not clipped ${both}`).toBe(false);
      }

      expect(Math.abs(top.avatar - 40), `the avatar is 40px at rest ${both}`).toBeLessThanOrEqual(0.5);
      expect(Math.abs(compact.avatar - 32), `and 32px in the compact bar ${both}`).toBeLessThanOrEqual(0.5);
      expect(compact.name, `the name shrinks with it ${both}`).toBeLessThan(top.name - 1);
      for (const at of [top, compact]) {
        expect(Math.abs(at.avatarRight - at.contentRight), `the avatar's right edge is the container's ${both}`).toBeLessThanOrEqual(1);
      }
      expect(Math.abs(compact.gap - top.gap), `the column follows the avatar in ${both}`).toBeLessThanOrEqual(1);
    });
  }

  // /tasks/turf-nav-links-follow. The logo link scales from its left edge by a
  // transform, which keeps its layout box, so before studio-engine 0.111.3 the
  // links beside it (Contests, Rules, geo badge, wallet signal) held still and
  // the gap from the wordmark to Contests grew from 24px to 109px collapsed.
  // The desktop nav now carries data-nav-links and slides left by
  // --nav-brand-shrink. Read on the PAINTED edges: the brand's
  // getBoundingClientRect() includes its transform.
  const brandGap = (page, y) => page.evaluate(async ([sel, y]) => {
    window.scrollTo(0, y);
    for (let i = 0; i < 2; i++) await new Promise((r) => requestAnimationFrame(r));
    const h = document.querySelector(sel);
    const brand = h.querySelector(".nav-logo-link").getBoundingClientRect();
    const contests = [...h.querySelectorAll("nav a")].find((a) => a.textContent.trim() === "Contests").getBoundingClientRect();
    return { y: Math.round(scrollY), gap: contests.left - brand.right, brand: brand.width };
  }, [HEADER, y]);
  const midBand = (page) => page.locator(HEADER).evaluate((h) => {
    const css = getComputedStyle(h);
    return Math.round((parseFloat(css.getPropertyValue("--nav-start")) || 0) + parseFloat(css.getPropertyValue("--nav-band")) / 2);
  });

  for (const width of [1280, 1024]) {
    test(`at ${width} the desktop links keep their gap to the logo as it shrinks`, async ({ page }) => {
      await page.emulateMedia({ reducedMotion: "no-preference" });
      await page.setViewportSize({ width, height: 800 });
      await login(page, PLAYER);
      await page.goto("/contests");
      await settled(page);
      await expect(page.locator(`${HEADER} nav[data-nav-links]`)).toHaveCount(1);

      const top = await brandGap(page, 0);
      const mid = await brandGap(page, await midBand(page));
      const compact = await brandGap(page, 1200);
      const all = JSON.stringify({ top, mid, compact });
      expect(mid.brand, `mid-band is mid-shrink ${all}`).toBeLessThan(top.brand - 1);
      expect(compact.brand, `the brand is smaller collapsed ${all}`).toBeLessThan(mid.brand - 1);
      for (const at of [mid, compact]) {
        expect(Math.abs(at.gap - top.gap), `the gap to Contests holds ${all}`).toBeLessThanOrEqual(1);
      }

      // The hook is what holds it: without it the links stay put and the gap opens.
      await page.locator(`${HEADER} nav[data-nav-links]`).evaluate((n) => n.removeAttribute("data-nav-links"));
      const unhooked = await brandGap(page, 1200);
      expect(unhooked.gap - top.gap, `without data-nav-links the gap widens ${JSON.stringify(unhooked)}`).toBeGreaterThan(20);

      // Collapsed, Contests takes the pointer where it paints, and a click there
      // goes to it: start from the rules page so the navigation is real.
      await page.goto("/turf-monster-v1");
      await settled(page);
      const scrolled = await page.evaluate(async () => {
        window.scrollTo(0, 1200);
        for (let i = 0; i < 2; i++) await new Promise((r) => requestAnimationFrame(r));
        return scrollY;
      });
      expect(scrolled, "the rules page scrolls past the band").toBeGreaterThan(200);
      const contests = page.locator(`${HEADER} nav[data-nav-links] a`, { hasText: "Contests" });
      const hit = await contests.evaluate((a) => {
        const r = a.getBoundingClientRect();
        const el = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
        return el === a || a.contains(el);
      });
      expect(hit, "Contests is on top at its painted centre, collapsed").toBe(true);
      await contests.click();
      await expect(page).toHaveURL(/\/contests$/);
    });
  }

  // The logo link is the min-w-0 item that gives way when the row runs short,
  // and at 768 the links end 27px short of their column. Something in the nav
  // that hydrates wider (the geo badge, the wallet signal) narrows the logo link
  // with no window resize; app/javascript/nav_band_watch.js re-measures then, so
  // --nav-brand-shrink follows the logo link's new width and the gap holds.
  test("at 768 a nav that grows after load narrows the logo, and the gap still holds", async ({ page }) => {
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await page.setViewportSize({ width: 768, height: 800 });
    await login(page, PLAYER);
    await page.goto("/contests");
    await settled(page);
    const header = page.locator(HEADER);
    const before = await header.evaluate((h) => ({ w: h.querySelector(".nav-logo-link").offsetWidth, shrink: h.style.getPropertyValue("--nav-brand-shrink") }));

    await header.evaluate((h) => {
      const pad = Object.assign(document.createElement("span"), { textContent: "" });
      pad.setAttribute("data-test-pad", "");
      pad.style.cssText = "display:inline-block;flex:none;width:90px";
      h.querySelector("nav[data-nav-links]").appendChild(pad);
    });
    await expect.poll(() => header.evaluate((h) => h.querySelector(".nav-logo-link").offsetWidth),
      { message: "the logo link narrows" }).toBeLessThan(before.w - 20);
    await expect.poll(() => header.evaluate((h) => h.style.getPropertyValue("--nav-brand-shrink")),
      { message: "--nav-brand-shrink is re-measured" }).not.toBe(before.shrink);

    const top = await brandGap(page, 0);
    const mid = await brandGap(page, await midBand(page));
    const compact = await brandGap(page, 1200);
    const all = JSON.stringify({ before, top, mid, compact });
    for (const at of [mid, compact]) {
      expect(Math.abs(at.gap - top.gap), `the gap to Contests holds on the narrowed logo ${all}`).toBeLessThanOrEqual(1);
    }
  });
});
