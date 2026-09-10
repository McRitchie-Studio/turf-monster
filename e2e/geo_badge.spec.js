const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// The navbar geo badge.
//
// WHAT THIS LANE CAN AND CANNOT SEE, because the old version of this file got
// it wrong in a way that read as coverage:
//
// Playwright talks to the server on 127.0.0.1, so `request.remote_ip` is
// LOOPBACK and that is what gets geocoded — never the runner's public address.
// Measured: Geocoder.search("127.0.0.1") returns {"ip":"127.0.0.1","bogon":true}
// with no region and no country. So geo_state is nil on every unpinned request
// and the badge reads "??" DETERMINISTICALLY. Nothing pins geo_country in this
// repo (no hits in e2e/, playwright.config.js or .github/workflows/), and
// nothing needs to — the loopback answer is stable, not lucky.
//
// The old assertion was `toHaveText(/^\s*([A-Z]{2}|\?\?)\s*$/)`. Every run took
// the "??" branch, so the [A-Z]{2} half was unreachable and the flag path was
// never exercised at all — the file would have stayed green if flag rendering
// were deleted outright. It then became actively wrong when the badge learned
// to render a country flag plus a region name for non-US visitors ("🇨🇦 Alberta"
// fails that regex), which is what surfaced all of the above.
//
// So this file now pins the state through the app's own admin override instead
// of hoping the network answers, and asserts the branch it pins.
//
// STILL NOT COVERED HERE, deliberately: the non-US country-flag branch. The
// override forces country "US" by design (Studio::GeoDetection#geo_country),
// and the only other way to reach a foreign IP is a real ipinfo lookup over the
// network — a flake, not a test. That branch belongs to
// test/views/geo_badge_render_test.rb, which covers it properly and is
// mutation-verified, including the trap where a foreign region code colliding
// with a US state must NOT render the US state flag. (The engine carries the
// same coverage against its own partial, which this app now renders.)
test.describe("Geo badge", () => {
  test.beforeEach(async ({ request }) => await reseed(request));

  // The badge is PUBLIC — detection is IP-based and runs for every request, so
  // it must render with no signed-in user. There is no logged_in? gate, and a
  // partial that grew one would fail here.
  test("renders for a signed-out visitor, undetectable and honest about it", async ({
    page,
  }) => {
    await page.goto("/contests");

    const badge = page.locator("nav .geo-badge").first();
    await expect(badge).toBeVisible();
    // Loopback cannot be placed, and an undetectable location must SAY so
    // rather than vanish or guess.
    await expect(badge).toHaveText(/\?\?/);
    await expect(badge.locator("img")).toHaveCount(0);
  });

  // The branch this lane never used to reach. The admin override pins a state
  // in-session (GeoSettingsController#toggle_override), so the badge is being
  // measured, not the network.
  test("a pinned state renders its code and its flag", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/contests");

    // POST admin/geo/toggle — the app's own state simulator. It pins WA.
    await page.evaluate(async () => {
      const token = document.querySelector('meta[name="csrf-token"]')?.content;
      await fetch("/admin/geo/toggle", {
        method: "POST",
        headers: { "X-CSRF-Token": token },
      });
    });
    await page.reload();

    const badge = page.locator("nav .geo-badge").first();
    await expect(badge).toContainText("WA");
    // The flag is the half the old contract could never see.
    // The flag ships in the gem now, so it is served as an ASSET — a digested
    // path under /assets in production-like builds. Match the file, not the
    // fingerprint, or this pins the build rather than the badge.
    await expect(badge.locator('img[src*="state-flags/wa"]')).toHaveCount(1);
    // WA is on the published exclusion list AND the override is active, so the
    // badge must read as blocked rather than as an ordinary location. The blocked
    // look is an attribute plus one CSS rule now (so /admin/geo can repaint it
    // live), so assert what the eye reads: the colour.
    await expect(badge).toHaveAttribute("data-blocked", "true");
    await expect(badge).toHaveCSS("color", "rgb(248, 113, 113)");
  });
});
