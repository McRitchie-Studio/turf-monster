// Coverage for the 2026-05-23 audit consolidation (commit b2d986b).
// - Phase A + C7: toast z-index now read from CSS vars (no !important needed)
// - Phase B1:     invite-link handler reads loggedIn from #session-context JSON
// - Phase B2:     window.handleSolanaVerifySuccess centralizes the new_user flag
// - Phase C4:     admin/pending_transactions empty state uses engine partial

const { test, expect } = require("@playwright/test");
const { login, loginAdmin, reseed } = require("./helpers");

test.beforeEach(async ({ request }) => await reseed(request));

test.describe("Audit consolidation (2026-05-23)", () => {
  test.beforeEach(async ({ page }) => {
    // Each test starts with a clean localStorage so previous tests'
    // inviter_slug / show_profile_modal flags don't bleed through.
    await page.goto("/");
    await page.evaluate(() => localStorage.clear());
  });

  // Phase A + C7
  test("toast container z-index resolves to 200 via CSS var (no !important in app)", async ({ page }) => {
    await page.goto("/");
    const z = await page.evaluate(() => {
      const el = document.getElementById("toast-container");
      return el ? getComputedStyle(el).zIndex : null;
    });
    expect(z).not.toBeNull();
    // turf-monster's :root sets --studio-toast-z: 200 (above navbar z-[110]
    // and modal backdrop z-[120]); engine 0.4.10 reads via var().
    expect(parseInt(z, 10)).toBe(200);

    const blurZ = await page.evaluate(() => {
      const el = document.querySelector(".toast-page-blur");
      return el ? getComputedStyle(el).zIndex : null;
    });
    expect(parseInt(blurZ, 10)).toBe(199);
  });

  // Phase B1
  test("invite-link: body has NO data-logged-in attribute (migrated to JSON read)", async ({ page }) => {
    await page.goto("/");
    const hasAttr = await page.evaluate(() => document.body.hasAttribute("data-logged-in"));
    expect(hasAttr).toBe(false);
  });

  test("invite-link: ?ref= is captured into localStorage as a guest", async ({ page }) => {
    await page.goto("/contests?ref=alex");
    const ref = await page.evaluate(() => localStorage.getItem("inviter_slug"));
    expect(ref).toBe("alex");
    // URL should be cleaned (ref param removed)
    expect(page.url()).not.toContain("ref=");
    // #session-context confirms we're a guest
    const ctx = await page.evaluate(() => {
      const el = document.getElementById("session-context");
      return el ? JSON.parse(el.textContent) : null;
    });
    expect(ctx).not.toBeNull();
    expect(ctx.loggedIn).toBe(false);
  });

  test("invite-link: PATCH /account/set_inviter fires when logged-in user navigates with stored inviter_slug", async ({ page }) => {
    // Login first so the session cookie is set.
    await login(page, "mason@mcritchie.studio", "password");

    // Simulate a prior guest visit having captured ?ref=alex into localStorage.
    await page.evaluate(() => localStorage.setItem("inviter_slug", "alex"));

    // Now register the request listener and trigger a turbo:load via navigation.
    // The handler in application.html.erb reads loggedIn from #session-context
    // JSON (no longer from data-logged-in) and posts to /account/set_inviter.
    const setInviterRequests = [];
    page.on("request", (req) => {
      if (req.url().includes("/account/set_inviter")) {
        setInviterRequests.push({ method: req.method(), postData: req.postData() });
      }
    });

    await page.goto("/contests");
    // Handler runs on turbo:load; give it a moment to fire its fetch.
    // The server may 404 if no user with slug 'alex' exists in this DB —
    // we only care that the CLIENT sent the request.
    await page.waitForTimeout(2000);

    expect(setInviterRequests.length).toBeGreaterThanOrEqual(1);
    expect(setInviterRequests[0].method).toBe("PATCH");
    expect(setInviterRequests[0].postData).toContain("alex");
  });

  // Phase B2 — the new-Phantom-signup avatar prompt (the 'profile' modal) was
  // RETIRED (2026-06-06): usernames auto-generate, so there's nothing to
  // complete. handleSolanaVerifySuccess remains as a safe no-op post-verify
  // hook and must NEVER set show_profile_modal.
  test("window.handleSolanaVerifySuccess is a safe no-op (profile prompt retired)", async ({ page }) => {
    await page.goto("/");
    const helperExists = await page.evaluate(
      () => typeof window.handleSolanaVerifySuccess === "function"
    );
    expect(helperExists).toBe(true);

    // new_user: true -> flag still NOT set (prompt retired)
    await page.evaluate(() => {
      localStorage.removeItem("show_profile_modal");
      window.handleSolanaVerifySuccess({ success: true, new_user: true });
    });
    let flag = await page.evaluate(() => localStorage.getItem("show_profile_modal"));
    expect(flag).toBeNull();

    // null/undefined input is safe (no throw)
    await page.evaluate(() => window.handleSolanaVerifySuccess(null));
    flag = await page.evaluate(() => localStorage.getItem("show_profile_modal"));
    expect(flag).toBeNull();
  });

  // Phase C4
  test("admin/pending_transactions empty state renders via engine partial", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/admin/pending_transactions");

    const emptyState = page.locator(".empty-state");
    await expect(emptyState).toBeVisible();
    await expect(emptyState).toContainText("No treasury transactions yet.");
    await expect(emptyState).toContainText("Multisig transactions requiring cosigning will appear here.");
    // Engine partial wraps the message in <p class="text-secondary text-lg">.
    await expect(emptyState.locator("p.text-lg")).toHaveCount(1);
  });
});
