const { test, expect } = require("@playwright/test");
const { attestAge, loginAdmin, reseed } = require("./helpers");

// [e2e] The TikTok claim funnel, end to end: a follower types
// turfmonster.media/tiktok, presses "Claim Your Free Entry", signs up, and lands
// on "You're in"; the operator then finds them on /admin/free_entries by source
// and presses Grant 1.
//
// WHY A BROWSER. The claim rides a return path through /signin's Alpine card
// into the magic-link request, and attribution rides a cookie across the vanity
// redirect and the signup. Each piece has a lower-tier test
// (landing_claim_flow_test.rb, free_entries_*_test.rb); only a browser proves
// they compose — and that the CTA a visitor actually clicks never reaches the
// contest checkout.
//
// TWO THINGS ARE DELIBERATELY NOT DONE HERE, and each is proven one tier down:
//   * The magic link is minted by /test/magic_link_token (same return path)
//     rather than read out of an inbox; the spec asserts the REAL /signin form
//     posted that return path, which is the half only a browser can show.
//   * The Grant POST is intercepted and never reaches the controller: an
//     on-chain mint is not something a PR lane may perform. That the confirmed
//     grant sends exactly one "free entry is ready" email, and a failed or
//     refused one sends none, is pinned in free_entries_grant_test.rb.
test.beforeEach(async ({ request }) => await reseed(request));

// Turn the seeded tiktok page into a live claim-mode page through the real
// admin form (db/seeds/landing_pages.rb seeds it; active only when a featured
// contest existed at seed time, so the spec sets both here).
async function publishClaimPage(page) {
  await loginAdmin(page);
  const edit = await page.goto("/admin/landing_pages/tiktok/edit");
  expect(edit.ok(), "the seeded tiktok landing page must exist").toBeTruthy();
  const contestSelect = page.locator("select[name='landing_page[contest_id]']");
  const firstContest = await contestSelect.locator("option:not([value=''])").first().getAttribute("value");
  await contestSelect.selectOption(firstContest);
  await page.locator("input[type=checkbox][name='landing_page[active]']").check();
  await page.locator("input[type=checkbox][name='landing_page[claim_mode]']").check();
  await page.getByRole("button", { name: "Save Changes" }).click();
  await page.waitForURL((u) => !u.pathname.endsWith("/edit"));
}

test.describe("TikTok claim funnel to a hand-minted free entry", () => {
  test("a /tiktok visitor claims, lands on You're in, and is offered Grant 1 @smoke", async ({ browser }) => {
    const adminContext = await browser.newContext();
    const admin = await adminContext.newPage();
    await publishClaimPage(admin);

    // ── The follower ────────────────────────────────────────────────────────
    const fanContext = await browser.newContext();
    const fan = await fanContext.newPage();

    await fan.goto("/tiktok");
    await expect(fan).toHaveURL(/\/lp\/tiktok$/);
    const refCookie = (await fanContext.cookies()).find((c) => c.name === "reference");
    expect(refCookie?.value, "visiting /tiktok must tag the visitor").toBe("tiktok");

    // The claim steps, in claim order: the account and the promised entry come
    // before the picks, so nothing sends a token-less visitor to a checkout.
    const steps = fan.locator("[data-test='funnel-how-it-works'] p.text-heading");
    await expect(steps.first()).toHaveText("Create your account");
    await expect(steps.nth(1)).toHaveText("We email your free entry");

    const cta = fan.locator("[data-test='claim-cta']");
    expect(await cta.getAttribute("href")).not.toContain("/contests/");
    await cta.click();
    await fan.waitForURL(/\/signin\?/);
    const signin = new URL(fan.url());
    expect(signin.searchParams.get("return_to")).toBe("/lp/tiktok/claimed");
    expect(signin.searchParams.get("reference")).toBe("tiktok");

    // The real /signin card must post the return path with the email.
    const email = `tiktok-fan-${Date.now()}@example.com`;
    const requested = fan.waitForRequest((r) => r.url().endsWith("/magic_link") && r.method() === "POST");
    await attestAge(fan);
    await fan.locator("#email").fill(email);
    await fan.getByRole("button", { name: "Email Link" }).click();
    const body = new URLSearchParams((await requested).postData() || "");
    expect(body.get("email")).toBe(email);
    expect(body.get("return_to"), "the card must forward return_to into the magic link").toBe("/lp/tiktok/claimed");

    // Open "the emailed link": same email, same return path.
    const linkRes = await fan.request.post("/test/magic_link_token", {
      data: { email, return_to: "/lp/tiktok/claimed" },
    });
    expect(linkRes.ok()).toBeTruthy();
    await fan.goto((await linkRes.json()).url);
    const consumeButton = fan.locator('button:has-text("Sign in to Turf Monster")');
    if (await consumeButton.isVisible().catch(() => false)) await consumeButton.click();
    await fan.waitForURL(/\/lp\/tiktok\/claimed$/);

    await expect(fan.locator("h1")).toHaveText("You're in.");
    await expect(fan.locator("[data-test='claim-email']")).toHaveText(email);

    // A wallet to mint to, and the chain's answer for a brand-new user: nothing
    // minted. A cold row offers no buttons at all.
    const walletRes = await fan.request.post("/test/grant_managed_wallet");
    expect(walletRes.ok(), `grant_managed_wallet failed: ${walletRes.status()}`).toBeTruthy();
    const { slug } = await walletRes.json();
    const warm = await fan.request.post("/test/warm_entry_tokens", { form: { minted: "0" } });
    expect(warm.ok(), `warm_entry_tokens failed: ${warm.status()} ${await warm.text()}`).toBeTruthy();
    await fanContext.close();

    // ── The operator ────────────────────────────────────────────────────────
    await admin.goto("/admin/free_entries");
    await admin.locator("select#reference").selectOption("tiktok");
    await admin.getByRole("button", { name: "Filter" }).click();
    await admin.waitForURL(/reference=tiktok/);

    const row = admin.locator("#users-tbody tr", { has: admin.locator(`form[action*="/${slug}/"]`) });
    await expect(row).toHaveCount(1);
    await expect(row.locator("[data-test='signup-source']")).toHaveText("tiktok");

    const grants = [];
    await admin.route("**/admin/free_entries/*/grant**", async (route) => {
      grants.push(route.request().url());
      await route.fulfill({ status: 302, headers: { Location: "/admin/free_entries?reference=tiktok" } });
    });
    let asked = null;
    admin.on("dialog", async (d) => {
      asked = d.message();
      await d.accept();
    });

    await row.getByRole("button", { name: "Grant 1" }).click();
    await expect.poll(() => grants.length).toBe(1);

    expect(asked, "Grant mints on-chain, so it must confirm first").toMatch(/Grant 1 free entry/);
    const posted = new URL(grants[0]);
    expect(posted.pathname).toBe(`/admin/free_entries/${slug}/grant`);
    expect(posted.searchParams.get("minted")).toBe("0");
    expect(posted.searchParams.get("reference")).toBe("tiktok");

    await adminContext.close();
  });
});
