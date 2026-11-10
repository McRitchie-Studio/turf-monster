const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed, seedRailContests, clearRailContests, createActiveEntry } = require("./helpers");

// /contests: THE MY CONTESTS TABLE LEAVES UNDER THE PINNED PAGE HEADER CLEANLY.
//
// Production report (turf-contests-header-stacking): signed in with entries and
// scrolled a little, the "Contests" title was cut off by a CONTEST / STATUS /
// ENTRY row drawn on top of it. That row was the engine's sticky table-header
// copy (studio/sticky_table_header): as My Contests scrolled out, the copy was
// pushed up by the table's bottom into the page header's band, and at the page
// header's own z-index it won the tie and painted over the title. studio-engine
// 0.141.3 keeps the copy at the pinned stack's bottom edge, shorter as the table
// leaves, and stacks it under the page header.
//
// The engine's own lab proves the primitive. This proves Turf's page: the real
// page header, the real My Contests card, the real glass bar. On every painted
// frame of a slow scroll through the table's exit, every showing copy's top is
// at or below the page header's bottom. Against the 0.141.2 engine it is red.
const DESKTOP = { width: 1280, height: 800 };
const PHONE = { width: 390, height: 844 };

const READ = () => {
  const row = document.querySelector('[data-pin="page"]').getBoundingClientRect();
  const table = document.querySelector('[data-contest-band="mine"] table').getBoundingClientRect();
  const clones = [...document.querySelectorAll(".sticky-table-header-clone")]
    .filter((c) => getComputedStyle(c).display !== "none")
    .map((c) => c.getBoundingClientRect());
  const r = (n) => Math.round(n * 10) / 10;
  return {
    y: Math.round(window.scrollY),
    rowBottom: r(row.bottom),
    tableBottom: r(table.bottom),
    clones: clones.map((b) => ({ top: r(b.top), bottom: r(b.bottom) }))
  };
};

async function setUp(page, size) {
  await page.setViewportSize(size);
  await loginAdmin(page);
  const { slugs } = await seedRailContests(page, 3);
  for (const slug of slugs) await createActiveEntry(page, slug);
  await page.goto("/contests");
  await expect(page.locator('[data-contest-band="mine"] table tbody tr')).toHaveCount(slugs.length);
  // The engine boots one copy per table on load.
  await expect(page.locator(".sticky-table-header-clone")).not.toHaveCount(0);
  await page.evaluate(() => document.fonts.ready);
}

async function sweepThroughExit(page) {
  // Start with My Contests' header row 200px below the page header, then scroll
  // 4px a painted frame until the table is gone above it.
  const start = await page.evaluate(() => {
    const table = document.querySelector('[data-contest-band="mine"] table');
    const row = document.querySelector('[data-pin="page"]');
    return Math.max(0, Math.round(table.getBoundingClientRect().top + window.scrollY - row.offsetHeight - 300));
  });
  return page.evaluate(async ({ start, readSrc }) => {
    const read = eval(`(${readSrc})`);
    const painted = () => new Promise((resolve) => requestAnimationFrame(() => setTimeout(resolve, 0)));
    window.scrollTo(0, start);
    await painted();
    const rows = [];
    for (let i = 0; i < 400; i++) {
      window.scrollBy(0, 4);
      await painted();
      const r = read();
      rows.push(r);
      if (r.tableBottom < r.rowBottom - 40) break;
    }
    return rows;
  }, { start, readSrc: READ.toString() });
}

function expectNeverOverTitle(rows, label) {
  const shown = rows.filter((r) => r.clones.length > 0);
  expect(shown.length, `${label}: a copy showed while My Contests scrolled out`).toBeGreaterThan(0);
  const over = shown.filter((r) => r.clones.some((c) => c.top < r.rowBottom - 0.5));
  expect(over, `${label}: frames where a copy's top rose above the page header's bottom`).toEqual([]);
  // The premise: the sweep reached the frames where the table was leaving and
  // the copy was cut short, or it never tested the exit.
  const cut = shown.filter((r) => r.clones.some((c) => c.bottom - c.top < 30));
  expect(cut.length, `${label}: frames where the copy was cut at the edge`).toBeGreaterThan(0);
}

test.beforeEach(async ({ request }) => await reseed(request));
test.afterEach(async ({ page }) => await clearRailContests(page));

test("1280px: My Contests leaves under the pinned page header without its copy covering the title", async ({ page }) => {
  await setUp(page, DESKTOP);
  expectNeverOverTitle(await sweepThroughExit(page), "1280px");
});

test("390px: My Contests leaves under the pinned page header without its copy covering the title", async ({ page }) => {
  await setUp(page, PHONE);
  expectNeverOverTitle(await sweepThroughExit(page), "390px");
});
