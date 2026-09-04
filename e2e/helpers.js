const { setupPhantomMock, MOCK_PUBKEY_B58 } = require("./phantom-mock");
const { setupOnchainMocks, computeMockTransaction } = require("./rpc-mock");

/**
 * Log in (or create the account) via the magic link.
 * Email auth is now a passwordless magic link, so there's no form to fill —
 * we mint a token through the dev-only /test/magic_link_token endpoint and
 * navigate to the emailed URL (same browser context, so the session cookie
 * sticks). The `password` arg is ignored (kept for call-site compatibility).
 *
 * The emailed link's GET is a scanner-safe interstitial that does NOT consume
 * the token on the server; it AUTO-SUBMITS the consume form via JS on load, so a
 * real browser signs in with no manual tap. We just navigate and wait for the
 * redirect off /magic_link (with a button-click fallback for safety).
 * Waits for the URL to leave /signin and /magic_link.
 */
async function login(page, email, _password) {
  const resp = await page.request.post("/test/magic_link_token", { data: { email } });
  if (!resp.ok()) {
    throw new Error(`magic_link_token failed: ${resp.status()} ${await resp.text()}`);
  }
  const { url } = await resp.json();
  await page.goto(url);
  const leftMagicLink = (u) =>
    !u.pathname.startsWith("/signin") && !u.pathname.startsWith("/magic_link");
  try {
    await page.waitForURL(leftMagicLink, { timeout: 5000 });
  } catch (_) {
    // Auto-submit didn't fire (no-JS fallback) — click the consume button.
    await page.locator('button:has-text("Sign in to Turf Totals")').click();
    await page.waitForURL(leftMagicLink);
  }
}

/**
 * Tick the legal-age attestation checkbox (underwriting compliance) on the
 * current auth surface — /signin card, in-contest auth modal, or the wallet
 * picker. Every credential CTA is gated on it client-side.
 *
 * No-op when the attestation flag is off (ENABLE_AGE_ATTESTATION unset —
 * the parked default): the checkbox doesn't render and the CTAs are
 * ungated, so there is nothing to tick.
 */
async function attestAge(page) {
  const box = page.locator("input[data-age-attestation]:visible").first();
  const present = await box
    .waitFor({ state: "visible", timeout: 1000 })
    .then(() => true)
    .catch(() => false);
  if (present) await box.check();
}

/**
 * Log in as admin user (alex@mcritchie.studio).
 */
async function loginAdmin(page) {
  await login(page, "alex@mcritchie.studio", "password");
}

/**
 * Log in via Phantom wallet mock.
 * Requires setupPhantomMock(page) to have been called first (injects
 * window.phantom, which the legacy PhantomProvider surfaces in the hub).
 * Opens the multi-wallet hub, then picks the detected (mock) Phantom wallet.
 */
async function loginViaPhantom(page) {
  await page.goto("/signin");
  // Legal-age attestation gates the auth CTAs (underwriting compliance);
  // checking the card box pre-checks the wallet picker's own checkbox.
  await attestAge(page);
  await page.locator('button:has-text("Solana")').click();
  // The hub reads walletProvider.available() at click time; wait for the
  // detected-wallet button to appear once the wallet_provider module loads.
  const wallet = page.locator('button:has-text("phantom")').first();
  await wallet.waitFor({ state: "visible" });
  await wallet.click();
  await page.waitForURL((url) => !url.pathname.startsWith("/signin"));
}

/**
 * Reset cross-spec pollution sources before a spec runs.
 *
 * Posts to POST /test/reseed (TestController#reseed), which clears:
 *   - rack-attack throttle counters (otherwise loginAdmin times out
 *     after a previous spec's repeated logins hit `login/email` 5/min)
 *   - entry-token Rails.cache keys (stale post-mint reads linger ~60s)
 *   - OmniAuth.config.mock_auth (leftover provider hashes from prior
 *     set_oauth_mock calls would sign in the wrong user)
 *
 * Call this in test.beforeEach for any spec that does ≥1 login per
 * test or touches token state — once-per-file (beforeAll) is NOT
 * enough; a single spec doing 6 admin logins (financial, geo,
 * admin-security) blows past `login/email`'s 5/min throttle mid-file.
 * The reseed POST is a few milliseconds — cheap to use defensively.
 */
async function reseed(request) {
  const response = await request.post("/test/reseed");
  if (!response.ok()) {
    throw new Error(`reseed failed: ${response.status()} ${await response.text()}`);
  }
  return await response.json();
}

/**
 * Give the current session's user an :active Entry on a contest (TestController
 * #create_active_entry). Fires the same Entry#after_commit the real /enter would
 * — flips User#contest_entered (so can_change_username? unlocks) and makes the
 * user a chat_participant — without the on-chain Vault dance devnet needs.
 *
 * This is what makes the quest card render: the contest show page gates it on
 * @has_entry (an :active/:complete entry on this contest).
 */
async function createActiveEntry(page, contestSlug) {
  const res = await page.request.post("/test/create_active_entry", {
    data: { contest_slug: contestSlug },
  });
  if (!res.ok()) {
    throw new Error(`create_active_entry failed: ${res.status()} ${await res.text()}`);
  }
  return res.json();
}

/**
 * Give the signed-in user a managed (custodial) wallet — a GRANDFATHERED web2
 * user (TestController#grant_managed_wallet).
 *
 * Web3-only onboarding (ENABLE_WEB3_ONLY_ONBOARDING) stopped signup from
 * minting one, so a spec about the managed-wallet path has to ask for it
 * explicitly rather than inherit it from signing up.
 */
async function grantManagedWallet(page) {
  const res = await page.request.post("/test/grant_managed_wallet");
  if (!res.ok()) {
    throw new Error(`grant_managed_wallet failed: ${res.status()} ${await res.text()}`);
  }
  return res.json();
}

/**
 * Stage the current user's quest ladder position (TestController#set_quest_state)
 * so a spec can land on a given quest_step / next_quest without driving the
 * on-chain username + chat quests first. Pass any of:
 *   { username_changed: true, chat_sent: true, subscribed: true }
 * Returns { quest_step, next_quest } for assertions.
 */
async function setQuestState(page, opts = {}) {
  const res = await page.request.post("/test/set_quest_state", { data: opts });
  if (!res.ok()) {
    throw new Error(`set_quest_state failed: ${res.status()} ${await res.text()}`);
  }
  return res.json();
}

/**
 * Stub the three quest endpoints whose REAL responses depend on an on-chain
 * seed grant (Solana::Vault) against a live program.
 *
 * Why this is needed: e2e test contests are created OFF-CHAIN
 * (skip_onchain_callback in e2e/seed.rb), so none of these reach a deployed
 * turf-vault program. The real responses chainless are therefore:
 *   - update_username  → { success:false } (Vault#set_username / build_set_username raises)
 *   - messages#create  → { ok:true } with NO seeds_earned (grant deferred) → the
 *                        quest arrow RESETS to idle instead of going to the checkmark,
 *                        and the card never advances chat → newsletter.
 *   - newsletter#subscribe → succeeds, but hits the RPC for the grant first.
 * Stubbing returns the success payload the server emits AFTER a confirmed grant,
 * so the REAL client orchestration runs (completeQuest → quest-advance crossfade,
 * the arrow idle→spinner→checkmark, quest-success / newsletter-success modal
 * swaps, the web3 add-email capture) with zero devnet. We never assert on-chain
 * seed totals here — real on-chain seed coverage lives in e2e/devnet-smoke.spec.js.
 *
 * Mirrors the page.route interception pattern in e2e/rpc-mock.js
 * (setupOnchainMocks). Non-POST requests fall through (route.fallback) so any
 * GET on these paths still hits the real server.
 */
async function stubQuestEndpoints(page, opts = {}) {
  const seeds = {
    seeds_earned: opts.seedsEarned ?? 25,
    seeds_total: opts.seedsTotal ?? 25,
    seeds_level: opts.seedsLevel ?? 0,
  };

  // Username rename (on-chain set_username) — return the confirmed-rename payload in
  // the studio-engine leveling-activity neutral contract ({ status: "saved", ... }).
  await page.route("**/account/update_username", async (route) => {
    if (route.request().method() !== "POST") return route.fallback();
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ status: "saved", username: "renamed-quest", ...seeds }),
    });
  });

  // First chat message — seeds_earned only comes back on the first-ever message
  // when the grant runs. The ~600ms delay lets the quest arrow's idle→loading
  // spinner render before the success checkmark, so both states are observable.
  await page.route("**/contests/*/messages", async (route) => {
    if (route.request().method() !== "POST") return route.fallback();
    await new Promise((r) => setTimeout(r, 600));
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ ok: true, ...seeds }),
    });
  });

  // Newsletter join — the subscription itself persists chainless, but the grant
  // is on-chain. A clean success keeps the flow fast + deterministic and lets a
  // spec assert the web3-captured email reached the request body.
  await page.route("**/account/newsletter/subscribe", async (route) => {
    if (route.request().method() !== "POST") return route.fallback();
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ success: true, subscribed: true, ...seeds }),
    });
  });
}


/**
 * OPT OUT OF THE LANE'S REDUCED MOTION, for a spec that tests animation.
 *
 * playwright.config.js sets `contextOptions.reducedMotion: "reduce"`, and since
 * /tasks/make-reduced-motion-reach-specs that setting actually REACHES the page.
 * The app honors it: `.free-entry-glow`, `.legendary-badge`, the modal mount /
 * unmount curves, `.holo-card` and six more selectors all collapse to
 * `animation: none` under the query.
 *
 * So a spec that asserts a RUNNING timeline — getAnimations(), a mid-flight
 * currentTime, a frame-to-frame paint diff — must turn motion back on first, and
 * must do it out loud rather than inherit it by luck:
 *
 *     await allowMotion(page);
 *
 * Call it BEFORE the navigation whose paint you intend to measure.
 */
async function allowMotion(page) {
  await page.emulateMedia({ reducedMotion: "no-preference" });
}

/**
 * The human operator's USERNAME, as seeded by db/seeds/users.rb.
 *
 * It lives here because three specs assert the nav chip's text and a fourth
 * builds a profile slug from it, and on 2026-09-04 it changed: `alex` and
 * `mcritchie` traded owners (the human took the bare name back; the shared team
 * account moved to `mcritchie`), which reddened the playwright lane in four
 * places at once. One literal is one edit next time.
 *
 * Keep it in step with User::PARKED_IDENTITIES — nothing enforces that from
 * JavaScript, so a rename is a two-file change by hand.
 */
const OPERATOR_USERNAME = "alex";

module.exports = {
  login,
  OPERATOR_USERNAME,
  loginAdmin,
  loginViaPhantom,
  reseed,
  createActiveEntry,
  grantManagedWallet,
  setQuestState,
  stubQuestEndpoints,
  setupPhantomMock,
  MOCK_PUBKEY_B58,
  setupOnchainMocks,
  computeMockTransaction,
  attestAge,
  allowMotion,
};
