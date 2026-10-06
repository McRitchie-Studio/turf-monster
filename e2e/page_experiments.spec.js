const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// [e2e] Page A/B testing, the way it is used: an admin binds a short link to
// the /turf-monster-v2 headline experiment, two strangers open it, each lands
// on a different variant (the headline and data-variant say which), each taps
// "Play Turf Monster", and the admin report shows one more visitor and one
// more tap in each arm.
//
// What only a browser proves: the /l/ hop's cookies ride a real 302 into the
// landing, the page's own script fires the CTA beacon (navigator.sendBeacon)
// on a real tap without holding up the tap, and the server credits the tap to
// the variant in the visitor's cookie.
//
// SEEDED ASSIGNMENT: each stranger's browser starts holding its variant cookie
// (exp_turf-monster-v2), so the split is deterministic; the draw itself is
// covered by the unit tests under a seeded RNG. The short link name is unique
// per run and the report is read as deltas, because reseed does not reset rows
// between specs or runs.
//
// A desktop Chrome UA, not Playwright's default: "HeadlessChrome" is a bot by
// ReferralVisit's rule, and a bot is never counted.
const DESKTOP_CHROME =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36";
const COOKIE = "exp_turf-monster-v2";
const ARMS = {
  control: ["Pick 6 teams.", "Stack points.", "Get paid."],
  "fantasy-football": ["NFL Team", "Fantasy", "Football"],
};

test.use({ userAgent: DESKTOP_CHROME });
test.beforeEach(async ({ request }) => {
  await reseed(request);
  const resp = await request.post("/test/seed_page_experiment");
  expect(resp.ok()).toBeTruthy();
});

async function readArm(page, key) {
  const row = page.locator(`[data-variant-row="${key}"]`);
  const visitors = parseInt(await row.locator('[data-cell="visitors"]').innerText(), 10);
  const taps = parseInt((await row.locator('[data-cell="cta-play"]').innerText()).trim().split(/\s+/)[0], 10);
  return { visitors, taps };
}

test("two visitors land on different variants and the report counts each arm", async ({ page, browser, baseURL }) => {
  const name = `ab-${Date.now().toString(36)}`;
  const host = new URL(baseURL).hostname;

  // The admin binds a fresh short link to the experiment.
  await loginAdmin(page);
  await page.goto("/admin/short_links/new");
  await page.getByLabel("Name").fill(name);
  await page.getByLabel("Goes to").fill("/turf-monster-v2");
  await page.getByLabel("Reference").fill(`${name}-bio`);
  await page.getByLabel("A/B experiment").selectOption("turf-monster-v2");
  await page.getByRole("button", { name: "Create Short Link" }).click();
  await expect(page).toHaveURL(/\/admin\/short_links$/);
  await expect(page.locator(`[data-short-link="${name}"] [data-short-link-experiment]`)).toHaveText("A/B: turf-monster-v2");

  await page.goto("/admin/experiments/turf-monster-v2");
  const before = { control: await readArm(page, "control"), "fantasy-football": await readArm(page, "fantasy-football") };

  for (const [key, headline] of Object.entries(ARMS)) {
    const visitor = await browser.newContext({ baseURL, userAgent: DESKTOP_CHROME });
    await visitor.addCookies([{ name: COOKIE, value: key, domain: host, path: "/" }]);
    const tab = await visitor.newPage();

    await tab.goto(`/l/${name}`);
    await expect(tab).toHaveURL(`${baseURL}/turf-monster-v2?r=${name}-bio&v=${key}`);
    const root = tab.locator('[data-test="turf-monster-v2"]');
    await expect(root).toHaveAttribute("data-variant", key);
    await expect(tab.locator('[data-test="v2-headline"] span')).toHaveText(headline);

    // The tap's beacon is fire-and-forget; wait for it to land before closing.
    const beacon = tab.waitForResponse(
      (r) => r.url().endsWith("/experiment-events") && (r.request().postData() || "").includes("play")
    );
    await tab.locator('[data-test="v2-hero-cta"]').click();
    expect((await beacon).status()).toBe(204);
    await visitor.close();
  }

  await page.reload();
  for (const key of Object.keys(ARMS)) {
    const after = await readArm(page, key);
    expect(after.visitors - before[key].visitors, `${key} visitors`).toBe(1);
    expect(after.taps - before[key].taps, `${key} Play taps`).toBe(1);
  }
});
