const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// [e2e] A LONG NAME NEVER COVERS THE ICONS (/tasks/turf-readopts-engine-navbar).
//
// studio-engine's account button is flex-shrink-0 and its name may grow to
// md:max-w-40, inside this app's fixed-width user column, so a 9+ character
// name drew over the theme toggle, the gear and the seeds bar's "Level" from
// 768px, and a click on the gear opened the account sidebar instead
// (Carl and Shannon's review block). application.css (THE NAME GIVES WAY, NOT
// THE ICONS) lets the account shrink and the name truncate in a 7rem cap.
//
// The name is set in the page to 30 characters: the layout under test is the
// same whatever wrote the text, and no seeded account carries a 30-character
// name. Removing that CSS turns every width here red.
const LONG_NAME = "abcdefghijklmnopqrstuvwxyz1234";
const HEADER = "header[data-navbar-root]";

for (const width of [768, 1024, 1280]) {
  test(`at ${width}px a 30-character name truncates clear of the toggle, the gear and the seeds bar`, async ({ page, request }) => {
    await reseed(request);
    await loginAdmin(page);
    await page.setViewportSize({ width, height: 800 });
    await page.goto("/contests");
    await expect(page.locator(`${HEADER} [data-nav-account]`)).toBeVisible();
    await page.waitForLoadState("networkidle");

    const m = await page.evaluate(async ([sel, name]) => {
      const h = document.querySelector(sel);
      // The name sits in the account (released engines) or ends row 1 over the
      // seeds bar (Studio.navbar_name_in_rows); either way the cap holds.
      const nameEl = h.querySelector("[data-nav-name]");
      nameEl.textContent = name;
      for (let i = 0; i < 2; i++) await new Promise((r) => requestAnimationFrame(r));
      const box = (el) => { const r = el.getBoundingClientRect(); return { left: r.left, right: r.right, top: r.top, bottom: r.bottom }; };
      const gear = h.querySelector("[data-nav-tools] [data-nav-menu-trigger] [data-gear-sidebar-trigger]");
      const toggle = h.querySelector("[data-nav-tools] [data-nav-theme-toggle='desktop']");
      const seeds = h.querySelector("[data-nav-seeds-row]");
      const g = box(gear);
      const hit = document.elementFromPoint((g.left + g.right) / 2, (g.top + g.bottom) / 2);
      return {
        name: box(nameEl), gear: g, toggle: box(toggle), seeds: box(seeds),
        truncated: nameEl.scrollWidth > nameEl.clientWidth,
        overflow: getComputedStyle(nameEl).textOverflow,
        hitGear: !!(hit && hit.closest("[data-gear-sidebar-trigger]")),
        hitAccount: !!(hit && hit.closest("[data-nav-account], [data-nav-name-trigger]")),
      };
    }, [HEADER, LONG_NAME]);
    const msg = JSON.stringify(m);
    const clear = (a, b) => a.right <= b.left + 0.5 || b.right <= a.left + 0.5 || a.bottom <= b.top + 0.5 || b.bottom <= a.top + 0.5;

    expect(m.truncated, `the name truncates: ${msg}`).toBe(true);
    expect(m.overflow, msg).toBe("ellipsis");
    for (const part of ["gear", "toggle", "seeds"]) {
      expect(clear(m.name, m[part]), `the name's box intersects the ${part}: ${msg}`).toBe(true);
    }
    expect(m.hitGear, `the gear's centre hits the gear: ${msg}`).toBe(true);
    expect(m.hitAccount, `the gear's centre must not hit the account button: ${msg}`).toBe(false);

    const g = m.gear;
    await page.mouse.click((g.left + g.right) / 2, (g.top + g.bottom) / 2);
    await expect(page.locator("#gear-sidebar")).toBeVisible();
  });
}

// [e2e] THE NAME STACKS OVER THE SEEDS BAR (/tasks/turf-navbar-name-stacks-over-level).
// Alex McRitchie: "the username and exp bar should stack like before" — before
// this app adopted the engine's user nav (turf e83522d5^1, components/_user_nav),
// the name ended row 1 after the moon and gear, directly over the seeds bar's
// Level, and the avatar stood alone to the right of both rows.
// config.navbar_name_in_rows does that on an engine that has the setting; on
// an older engine the name stays in the account and this test skips.
for (const width of [768, 1280]) {
  test(`at ${width}px the name sits over the seeds bar, both left of the avatar, and opens the gear sidebar`, async ({ page, request }) => {
    await reseed(request);
    await loginAdmin(page);
    await page.setViewportSize({ width, height: 800 });
    await page.goto("/contests");
    await expect(page.locator(`${HEADER} [data-nav-account]`)).toBeVisible();
    await page.waitForLoadState("networkidle");

    const inRows = await page.locator(`${HEADER} [data-nav-tools] [data-nav-name]`).count();
    test.skip(inRows === 0, "this studio-engine predates Studio.navbar_name_in_rows");

    const m = await page.evaluate((sel) => {
      const h = document.querySelector(sel);
      const box = (el) => { const r = el.getBoundingClientRect(); return { left: r.left, right: r.right, top: r.top, bottom: r.bottom }; };
      return {
        name: box(h.querySelector("[data-nav-name]")),
        seeds: box(h.querySelector("[data-nav-seeds-row]")),
        avatar: box(h.querySelector("[data-nav-account] > [aria-hidden]")),
        gear: box(h.querySelector("[data-nav-tools] [data-gear-sidebar-trigger]")),
        accountHasName: !!h.querySelector("[data-nav-account] [data-nav-name]"),
      };
    }, HEADER);
    const msg = JSON.stringify(m);

    expect(m.accountHasName, `the avatar stands alone: ${msg}`).toBe(false);
    expect(m.name.bottom, `the name sits above the seeds bar: ${msg}`).toBeLessThanOrEqual(m.seeds.top + 0.5);
    expect(m.name.right, `the name ends over the seeds bar: ${msg}`).toBeLessThanOrEqual(m.seeds.right + 0.5);
    expect(m.name.left, `the name starts over the seeds bar: ${msg}`).toBeGreaterThanOrEqual(m.seeds.left - 0.5);
    expect(m.name.left, `the name follows the gear: ${msg}`).toBeGreaterThanOrEqual(m.gear.right - 0.5);
    expect(m.name.right, `the name is left of the avatar: ${msg}`).toBeLessThanOrEqual(m.avatar.left + 0.5);
    expect(m.seeds.right, `the seeds bar is left of the avatar: ${msg}`).toBeLessThanOrEqual(m.avatar.left + 0.5);

    await page.locator(`${HEADER} [data-nav-name-trigger]`).click();
    await expect(page.locator("#gear-sidebar")).toBeVisible();
  });
}
