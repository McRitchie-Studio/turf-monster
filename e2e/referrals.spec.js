// Referral attribution + free-entry token UI.
//
// Three signup-flow tests exercise the ?ref= → localStorage → /account/set_inviter
// → invitees_count chain and the Entry#after_commit → ReferralProgress →
// invitees_in_contest_count chain, one per onboarding lane (Phantom, Google,
// Email). Two UI tests force the inviter's counters via the test endpoint and
// assert the /account widget renders the "1 of 2" and "ENTRY TOKEN COMING SOON"
// states.
//
// Bypasses the real /enter action — that hits Solana::Vault for paid
// onchain contests, which would need devnet in this test boot. Instead we
// POST /test/create_active_entry to create an :active Entry directly,
// which fires the same Entry#after_commit callback that the real /enter
// path would.

const { test, expect } = require("@playwright/test");
const { login, loginViaPhantom, setupPhantomMock, reseed } = require("./helpers");

test.beforeEach(async ({ request }) => await reseed(request));

const CONTEST_SLUG = "world-cup-2026";

// Seeded users — these slugs come from the deterministic E2E seed.
// CORE_USERS order: human (alex, id 1), team account (mcritchie, 2), mason (3),
// mack (4), turf (5). The first two traded usernames on 2026-09-04; only ids 1
// and 2 are affected, so the inviter slugs below are unchanged.
//
// A slug is "<username>-<id>", so RENAMING A USER RENAMES THIS CONSTANT. That is
// the whole reason it is spelled out here: the spec drives /referrals by slug,
// and a stale one 404s rather than failing an assertion, which reads like a
// broken page instead of a stale fixture.
//
// Every slug now carries its id. It did not always: Sluggable builds
// "<base>-<id>" in a before_save, which on CREATE runs before the id exists, so
// rows landed as "<base>-" and only gained the id if something saved them again.
// generate_managed_wallet! was that something — for non-admins only, which is
// why the admin rows kept the dangling shape and this file used to say "turf-".
// User#finalize_slug! settles it on create instead, so the shape no longer
// depends on which callbacks happened to fire.
const INVITER_FOR_PHANTOM = "mason-3";
const INVITER_FOR_GOOGLE  = "mack-4";
const INVITER_FOR_EMAIL   = "turf-5";
const ALEX_SLUG           = "alex-1"; // the human operator (id 1) — holds `alex` again after the 2026-09-04 username swap

// --- Helpers --------------------------------------------------------------

// Drop ?ref= on any page so the application layout's IIFE grabs it into
// localStorage. We use /faucet because it's a cheap, guest-friendly page
// — / redirects through to a contest which fires the leaderboard poll.
async function seedRef(page, refSlug) {
  await page.goto(`/faucet?ref=${refSlug}`);
  // The cleanup IIFE strips ?ref= and replaces history; wait for that.
  await page.waitForFunction(() => !window.location.search.includes("ref="));
}

async function setReferralCounts(page, slug, ic, iic) {
  const res = await page.request.post("/test/set_user_referral_counts", {
    data: { slug, invitees_count: ic, invitees_in_contest_count: iic },
  });
  expect(res.ok()).toBeTruthy();
}

async function getUserInfo(page, slug) {
  const res = await page.request.get(`/test/user_info/${slug}`);
  expect(res.ok()).toBeTruthy();
  return res.json();
}

async function submitGoogleOauth(page) {
  await page.evaluate(() => {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content || "";
    const form = document.createElement("form");
    form.method = "POST";
    // Attestation must ride the query string because OmniAuth snapshots
    // request.GET into omniauth.params during the request phase.
    form.action = "/auth/google_oauth2?age_attestation=1";

    const token = document.createElement("input");
    token.type = "hidden";
    token.name = "authenticity_token";
    token.value = csrfToken;
    form.appendChild(token);

    document.body.appendChild(form);
    form.submit();
  });
}

// Waits for the JS set_inviter handler that fires on turbo:load to land.
// Idempotent — if the user already has an inviter, the action 200s quickly.
async function waitForSetInviterAndCreateEntry(page, contestSlug) {
  // The turbo:load handler may have fired before we attach the listener;
  // give it up to 5s and fall back to issuing the call ourselves so the
  // attribution definitely lands before we create the entry.
  try {
    await page.waitForResponse(
      (r) => r.url().includes("/account/set_inviter") && r.status() < 400,
      { timeout: 5000 }
    );
  } catch (_e) {
    // Fallback: re-derive from localStorage and call directly.
    await page.evaluate(async () => {
      const slug = localStorage.getItem("inviter_slug");
      if (!slug) return;
      await fetch("/account/set_inviter", {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token":
            document.querySelector('meta[name="csrf-token"]')?.content || "",
        },
        body: JSON.stringify({ inviter_slug: slug }),
      });
      localStorage.removeItem("inviter_slug");
    });
  }

  const res = await page.request.post("/test/create_active_entry", {
    data: { contest_slug: contestSlug },
  });
  expect(res.ok()).toBeTruthy();
  return res.json();
}

// --- Signup-flow tests ----------------------------------------------------

test("ref → Phantom signup → entry credits the inviter", async ({ page }) => {
  // Start with a clean inviter slate so the +1/+1 assertion is unambiguous.
  await setReferralCounts(page, INVITER_FOR_PHANTOM, 0, 0);

  await setupPhantomMock(page, { seedByte: 3 });
  await seedRef(page, INVITER_FOR_PHANTOM);

  await loginViaPhantom(page);
  // Phantom auth → new user created → land on / → turbo:load fires set_inviter.
  // The profile modal may auto-open; we don't need to interact with it because
  // the user already has an auto-generated username from User#ensure_username.

  const entry = await waitForSetInviterAndCreateEntry(page, CONTEST_SLUG);
  expect(entry.inviter_slug).toBe(INVITER_FOR_PHANTOM);

  const inviter = await getUserInfo(page, INVITER_FOR_PHANTOM);
  expect(inviter.invitees_count).toBe(1);
  expect(inviter.invitees_in_contest_count).toBe(1);

  const newUser = await getUserInfo(page, entry.user_slug);
  expect(newUser.contest_entered).toBe(true);
  expect(newUser.inviter_slug).toBe(INVITER_FOR_PHANTOM);
});

test("ref → Google signup → entry credits the inviter", async ({ page }) => {
  await setReferralCounts(page, INVITER_FOR_GOOGLE, 0, 0);

  const ts = Date.now().toString(36);
  const googleEmail = `google-${ts}@test.com`;

  // Pin the OmniAuth mock payload so /auth/google_oauth2/callback creates THIS user.
  const mockRes = await page.request.post("/test/oauth_mock", {
    data: {
      provider: "google_oauth2",
      uid: `playwright-google-${ts}`,
      email: googleEmail,
      name: `Google Test ${ts}`,
    },
  });
  expect(mockRes.ok()).toBeTruthy();

  await seedRef(page, INVITER_FOR_GOOGLE);

  // OmniAuth request phase is POST-only for CSRF protection. Submit the same
  // form shape the app uses so test_mode short-circuits to the callback,
  // creates the user, signs them in, and redirects off /auth.
  await submitGoogleOauth(page);
  await page.waitForURL((url) => !url.pathname.startsWith("/auth/"));

  const entry = await waitForSetInviterAndCreateEntry(page, CONTEST_SLUG);
  expect(entry.inviter_slug).toBe(INVITER_FOR_GOOGLE);

  const inviter = await getUserInfo(page, INVITER_FOR_GOOGLE);
  expect(inviter.invitees_count).toBe(1);
  expect(inviter.invitees_in_contest_count).toBe(1);
});

test("ref → email signup → entry credits the inviter", async ({ page }) => {
  await setReferralCounts(page, INVITER_FOR_EMAIL, 0, 0);

  const ts = Date.now().toString(36);
  const email = `email-${ts}@test.com`;

  await seedRef(page, INVITER_FOR_EMAIL);

  // Email signup is a passwordless magic link now. Mint + consume a token;
  // the reference cookie set by seedRef() is read at consume time and written
  // onto the new user (same mechanism as the Google path above).
  const tokenResp = await page.request.post("/test/magic_link_token", { data: { email } });
  const { url } = await tokenResp.json();
  await page.goto(url);
  await page.waitForURL(
    (u) => !u.pathname.startsWith("/magic_link"),
    { timeout: 15_000 }
  );

  const entry = await waitForSetInviterAndCreateEntry(page, CONTEST_SLUG);
  expect(entry.inviter_slug).toBe(INVITER_FOR_EMAIL);

  const inviter = await getUserInfo(page, INVITER_FOR_EMAIL);
  expect(inviter.invitees_count).toBe(1);
  expect(inviter.invitees_in_contest_count).toBe(1);
});

// --- Account-page UI tests ------------------------------------------------

test("/account shows '1 of 2 friends' copy when one invitee has entered", async ({ page }) => {
  await login(page, "alex@mcritchie.studio", "password");

  await setReferralCounts(page, ALEX_SLUG, 1, 1);

  await page.goto("/account");

  await expect(page.locator("body")).toContainText("Bring ✌️ Friends, Get a Free Entry");
  await expect(page.locator("body")).toContainText("1 of 2 friends");
  await expect(page.locator("body")).not.toContainText("ENTRY TOKEN COMING SOON");
});

test("/account shows the ENTRY TOKEN COMING SOON badge when two invitees have entered", async ({ page }) => {
  await login(page, "alex@mcritchie.studio", "password");

  await setReferralCounts(page, ALEX_SLUG, 2, 2);

  await page.goto("/account");

  await expect(page.locator("body")).toContainText("Bring ✌️ Friends, Get a Free Entry");
  await expect(page.locator("body")).toContainText("ENTRY TOKEN COMING SOON");
  await expect(page.locator("body")).toContainText("2 friends entered");
});
