const { test, expect } = require("@playwright/test");
const { reseed, loginAdmin } = require("./helpers");

// Task turf-adopts-type-scale: every text-* class resolves to one of the five
// type roles at the element (app/assets/tailwind/type_scale.css is @theme
// inline), so what these assert is only observable in a live browser: the
// computed sizes, the dense base re-resolving under `type-dense`, and the
// board's shrinkTeamNames() stepping down the scale instead of off it.
test.beforeEach(async ({ request }) => await reseed(request));

const ROLES_16 = ["12px", "16px", "24px", "48px", "96px"];

test("team names sit on the scale and shrink a role at a time, never off it", async ({ page }) => {
  await page.setViewportSize({ width: 768, height: 900 });
  await page.goto("/contests/nfl-weeks-15-17");
  const names = page.locator(".team-name");
  await expect(names.first()).toBeVisible();

  const sizes = await names.evaluateAll((els) => els.map((el) => getComputedStyle(el).fontSize));
  expect(sizes.length).toBeGreaterThan(0);
  for (const size of sizes) expect(ROLES_16).toContain(size);
  // The mascot is the subhead role; most names keep it.
  expect(sizes.filter((size) => size === "24px").length).toBeGreaterThan(sizes.length / 2);

  // A name too long for any role steps down to fine print (12px), not the
  // off-scale 0.7rem (11.2px) the fitter used to jump straight to.
  const forced = await page.evaluate(() => {
    const el = document.querySelector(".team-name");
    el.textContent = "Commanders Commanders Commanders";
    window.shrinkTeamNames();
    return getComputedStyle(el).fontSize;
  });
  expect(forced).toBe("12px");

  // A name that overflows at subhead but fits at body stops at body. The box is
  // sized from the name's own measured widths, not a pixel guess, because font
  // metrics differ between macOS and the Linux CI runner.
  const body = await page.evaluate(() => {
    const el = document.querySelector(".team-name");
    el.textContent = "Commanders";
    el.style.display = "inline-block";
    el.style.maxWidth = "none";
    el.style.fontSize = "calc(var(--type-base, 16px) * 1)";
    const atBody = el.scrollWidth;
    el.style.fontSize = "";
    const atSubhead = el.scrollWidth;
    el.style.display = "";
    el.style.maxWidth = "";
    el.style.width = `${Math.round((atBody + atSubhead) / 2)}px`;
    window.shrinkTeamNames();
    return { atBody, atSubhead, size: getComputedStyle(el).fontSize, clipped: el.scrollWidth > el.clientWidth };
  });
  expect(body.atSubhead).toBeGreaterThan(body.atBody);
  expect(body.size).toBe("16px");
  expect(body.clipped).toBe(false);
});

test("an admin page reads the 14px dense base, a player page the 16px base", async ({ page }) => {
  await loginAdmin(page);

  await page.goto("/admin/dashboard");
  await expect(page.locator("body")).toHaveClass(/(^|\s)type-dense(\s|$)/);
  const dense = await page.evaluate(() => {
    const probe = document.createElement("span");
    probe.className = "text-sm";
    const fine = document.createElement("span");
    fine.className = "text-xs";
    document.body.append(probe, fine);
    return { body: getComputedStyle(probe).fontSize, fine: getComputedStyle(fine).fontSize };
  });
  expect(dense).toEqual({ body: "14px", fine: "10.5px" });

  await page.goto("/contests");
  await expect(page.locator("body")).not.toHaveClass(/(^|\s)type-dense(\s|$)/);
  const regular = await page.evaluate(() => {
    const probe = document.createElement("span");
    probe.className = "text-sm";
    document.body.append(probe);
    return getComputedStyle(probe).fontSize;
  });
  expect(regular).toBe("16px");
});
