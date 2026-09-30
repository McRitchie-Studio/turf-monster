const { test, expect } = require("@playwright/test");
const { login, loginAdmin, reseed } = require("./helpers");

// [e2e] The TikTok funnel, end to end: a follower types turfmonster.media/tiktok,
// signs up, and the operator finds them on /admin/free_entries by source and
// hand-mints their free entry.
//
// WHY A BROWSER. The attribution rides a COOKIE across two hops (the vanity
// redirect, then signup), and the operator's side is a GET filter form whose
// row buttons must carry that filter and the count the operator was shown.
// Each piece has a lower-tier test; only a browser proves they compose — that
// a real visitor's signup lands in the filtered table with a Grant button.
//
// The grant POST is intercepted at the network boundary and never reaches the
// controller: an on-chain mint is not something a PR lane may perform, and the
// controller's refusal rules are pinned in free_entries_grant_test.rb.
test.beforeEach(async ({ request }) => await reseed(request));

test.describe("TikTok funnel to a hand-minted free entry", () => {
  test("a /tiktok signup is filterable by source and offered Grant 1 @smoke", async ({ browser }) => {
    // ── The follower ────────────────────────────────────────────────────────
    const fanContext = await browser.newContext();
    const fan = await fanContext.newPage();

    const landing = await fan.goto("/tiktok");
    // db/seeds/landing_pages.rb seeds the tiktok page, active only when a
    // featured contest exists at seed time, so the visitor lands either on
    // /lp/tiktok or on the home-page fallback (which itself forwards to the
    // featured contest). Either is correct; what must hold is that the page
    // answered and the visitor now carries the attribution.
    expect(landing.ok(), `/tiktok ended on ${fan.url()} with ${landing.status()}`).toBeTruthy();
    const refCookie = (await fanContext.cookies()).find((c) => c.name === "reference");
    expect(refCookie?.value, "visiting /tiktok must tag the visitor").toBe("tiktok");

    const email = `tiktok-fan-${Date.now()}@example.com`;
    await login(fan, email); // magic-link signup creates the account from the cookie

    // A managed wallet is minted at signup; this returns it (and makes sure).
    const walletRes = await fan.request.post("/test/grant_managed_wallet");
    expect(walletRes.ok(), `grant_managed_wallet failed: ${walletRes.status()}`).toBeTruthy();
    const { slug } = await walletRes.json();

    // Warm the cache-first row with the chain's answer for a brand-new user:
    // nothing minted. A cold row offers no buttons at all.
    const warm = await fan.request.post("/test/warm_entry_tokens", { form: { minted: "0" } });
    expect(warm.ok(), `warm_entry_tokens failed: ${warm.status()} ${await warm.text()}`).toBeTruthy();
    await fanContext.close();

    // ── The operator ────────────────────────────────────────────────────────
    const adminContext = await browser.newContext();
    const page = await adminContext.newPage();
    await loginAdmin(page);
    await page.goto("/admin/free_entries");

    await page.locator("select#reference").selectOption("tiktok");
    await page.getByRole("button", { name: "Filter" }).click();
    await page.waitForURL(/reference=tiktok/);

    const row = page.locator("#users-tbody tr", { has: page.locator(`form[action*="/${slug}/"]`) });
    await expect(row).toHaveCount(1);
    await expect(row.locator("[data-test='signup-source']")).toHaveText("tiktok");
    // Only TikTok signups are listed.
    const sources = await page.locator("#users-tbody [data-test='signup-source']").allTextContents();
    expect(sources.map((s) => s.trim())).toEqual(sources.map(() => "tiktok"));

    const grants = [];
    await page.route("**/admin/free_entries/*/grant**", async (route) => {
      grants.push(route.request().url());
      await route.fulfill({ status: 302, headers: { Location: "/admin/free_entries?reference=tiktok" } });
    });
    let asked = null;
    page.on("dialog", async (d) => {
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
