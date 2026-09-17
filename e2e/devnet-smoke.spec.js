// @ts-check
const { test, expect } = require("@playwright/test");
const { execSync } = require("child_process");
const { setupKeypairProvider, BOT_PUBKEY } = require("./keypair-provider");

// All rails runner commands must target the test DB (Playwright webServer uses RAILS_ENV=test)
const RUNNER_OPTS = { cwd: process.cwd(), timeout: 15000, stdio: "pipe", env: { ...process.env, RAILS_ENV: "test" } };

/**
 * Devnet smoke tests — exercise the full Web3 flow against real devnet.
 *
 * Three test groups:
 *   1. Onboarding  — register + faucet for Alex, Mason, Mack (Tests 1-6)
 *   2. Small Contest — 3-entry onchain contest, lifecycle (Tests 7-12)
 *   3. Standard Contest — 30-entry DB-only multi-entry contest (Tests 13-17)
 *
 * Wallets are seeded via faucet before any contest actions, so tests only
 * require a small amount of pre-existing USDC ($20) to cover the gap.
 *
 * Prerequisites:
 *   - SOLANA_BOT_KEY env var set to the e2e bot wallet's (F6f8h5yy…) base58-encoded
 *     private key — the legacy pre-rotation signer, not Xan's SOLANA_ADMIN_KEY
 *     (see e2e/keypair-provider.js)
 *   - the bot wallet funded with ~0.2 SOL + ~$20 USDC on devnet
 *   - Mack wallet funded with ~1 SOL on devnet (USDC seeded by faucet test)
 *   - Test server seeded with SOLANA_BOT_PUBKEY=<bot pubkey>
 *
 * Run:
 *   SOLANA_BOT_KEY=<key> npx playwright test --project=devnet
 */

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const RPC_URL = process.env.SOLANA_RPC_URL || "https://api.devnet.solana.com";
const USDC_MINT = "222Dcu2RgAXE3T8A4mGSG3kQyXaNjqePx7vva1RdWBN9";
const MIN_SOL = 0.1;
const MIN_USDC = 20; // Low — faucet seeds $50 before contests need USDC

// Mack's wallet (Web3 registration + entry tests)
const MACK_KEY = "2miFBu2EGS6vZscu31GZcXc7WZew1bHG786HRX1nA4RTohyjfLmWVpsV7Vjdgc9wCajyTd4hkFY7T4HsqgAZkmFB";
const MACK_PUBKEY = "foUuRyeibadQoGdKXZ9pBGDqmkb1jY1jYsu8dZ29nds";

// Shared state across tests (serial execution)
let sharedSmallContestUrl;
let sharedStandardContestUrl;
let masonEmail;

// Balance snapshots — captured before/after for consumption tracking
let preflightSOL = 0;
let preflightUSDC = 0;

// Original wallet addresses — saved in beforeAll, restored in afterAll
let alexOriginalWallet = null;
let mackOriginalWallet = null;

// ---------------------------------------------------------------------------
// RPC helpers
// ---------------------------------------------------------------------------

async function rpcCall(method, params) {
  const res = await fetch(RPC_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const json = await res.json();
  if (json.error) throw new Error(`RPC ${method}: ${json.error.message}`);
  return json.result;
}

async function getSOLBalance(pubkey = BOT_PUBKEY) {
  const result = await rpcCall("getBalance", [pubkey]);
  return result.value / 1e9;
}

async function getUSDCBalance(pubkey = BOT_PUBKEY) {
  const result = await rpcCall("getTokenAccountsByOwner", [
    pubkey,
    { mint: USDC_MINT },
    { encoding: "jsonParsed" },
  ]);
  if (result.value && result.value.length > 0) {
    return result.value[0].account.data.parsed.info.tokenAmount.uiAmount || 0;
  }
  return 0;
}

// ---------------------------------------------------------------------------
// Pre-flight: validate env + snapshot balances
// ---------------------------------------------------------------------------

test.beforeAll(async () => {
  // 1. SOLANA_BOT_KEY must be set. Skip the whole spec when it's not
  // present so a default `npm test` run (which covers both chromium and
  // the @devnet project) doesn't fail on a missing local-dev secret.
  // CI / devnet runs explicitly supply the key.
  test.skip(
    !process.env.SOLANA_BOT_KEY,
    "SOLANA_BOT_KEY env var is required. Set it to the e2e bot wallet's (F6f8h5yy…) base58 private key."
  );

  // 2. Save original wallets, swap alex to bot key, clear Mack's wallet for fresh registration
  try {
    const saveScript = [
      `alex = User.find_by(email: 'alex@mcritchie.studio')`,
      `mack = User.find_by(username: 'mack')`,
      `puts alex&.web3_solana_address.to_s`,
      `puts mack&.web3_solana_address.to_s`,
    ].join("; ");
    const result = execSync(`bin/rails runner "${saveScript}"`, RUNNER_OPTS);
    const lines = result.toString().trim().split("\n");
    alexOriginalWallet = lines[0] || null;
    mackOriginalWallet = lines[1] || null;
    console.log(`Pre-flight — alex original wallet: ${alexOriginalWallet || "(none)"}`);
    console.log(`Pre-flight — mack original wallet: ${mackOriginalWallet || "(none)"}`);

    const script = [
      `pub = '${BOT_PUBKEY}'`,
      `User.where(web3_solana_address: pub).update_all(web3_solana_address: nil)`,
      `u = User.find_by(email: 'alex@mcritchie.studio')`,
      `u.update_column(:web3_solana_address, pub) if u`,
      `User.where(web3_solana_address: '${MACK_PUBKEY}').update_all(web3_solana_address: nil)`,
    ].join("; ");
    execSync(`bin/rails runner "${script}"`, RUNNER_OPTS);
    console.log(`Pre-flight — alex wallet linked to ${BOT_PUBKEY}`);
    console.log(`Pre-flight — mack wallet cleared (${MACK_PUBKEY})`);
  } catch (e) {
    console.warn(`Pre-flight — wallet link failed: ${e.message}`);
  }

  // 3. Snapshot balances
  preflightSOL = await getSOLBalance();
  preflightUSDC = await getUSDCBalance();

  const mackSOL = await getSOLBalance(MACK_PUBKEY);
  const mackUSDC = await getUSDCBalance(MACK_PUBKEY);

  console.log("┌─────────────────────────────────────┐");
  console.log("│         PRE-FLIGHT BALANCES          │");
  console.log("├─────────────────────────────────────┤");
  console.log(`│  Alex SOL:  ${preflightSOL.toFixed(4).padStart(9)} SOL          │`);
  console.log(`│  Alex USDC: $${preflightUSDC.toFixed(2).padStart(8)}              │`);
  console.log(`│  Mack SOL:  ${mackSOL.toFixed(4).padStart(9)} SOL          │`);
  console.log(`│  Mack USDC: $${mackUSDC.toFixed(2).padStart(8)}              │`);
  console.log("└─────────────────────────────────────┘");

  // 4. Fail fast if insufficient
  if (preflightSOL < MIN_SOL) {
    throw new Error(
      `Insufficient SOL: ${preflightSOL.toFixed(4)} < ${MIN_SOL}. ` +
        `Top up with: devnet-pow mine --target-lamports ${MIN_SOL * 1e9} -ud`
    );
  }
  if (preflightUSDC < MIN_USDC) {
    throw new Error(
      `Insufficient USDC: $${preflightUSDC.toFixed(2)} < $${MIN_USDC}. ` +
        `Top up via /faucet or CLI mint.`
    );
  }
});

// ---------------------------------------------------------------------------
// Post-flight: snapshot balances + log consumption
// ---------------------------------------------------------------------------

test.afterAll(async () => {
  // Clean up test-created users and restore original wallet addresses
  try {
    const cleanupScript = [
      // Clear wallets from any test-created users (avoids unique constraint on restore)
      `User.where(web3_solana_address: '${BOT_PUBKEY}').where.not(email: 'alex@mcritchie.studio').update_all(web3_solana_address: nil)`,
      `User.where(web3_solana_address: '${MACK_PUBKEY}').where.not(username: 'mack').update_all(web3_solana_address: nil)`,
      // Restore alex's original wallet
      alexOriginalWallet
        ? `User.find_by(email: 'alex@mcritchie.studio')&.update_column(:web3_solana_address, '${alexOriginalWallet}')`
        : null,
      // Restore mack's original wallet
      mackOriginalWallet
        ? `User.find_by(username: 'mack')&.update_column(:web3_solana_address, '${mackOriginalWallet}')`
        : null,
    ].filter(Boolean).join("; ");
    execSync(`bin/rails runner "${cleanupScript}"`, RUNNER_OPTS);
    if (alexOriginalWallet) console.log(`Post-flight — alex wallet restored to ${alexOriginalWallet}`);
    if (mackOriginalWallet) console.log(`Post-flight — mack wallet restored to ${mackOriginalWallet}`);
  } catch (e) {
    console.warn(`Post-flight — wallet restore failed: ${e.message}`);
  }

  const postSOL = await getSOLBalance();
  const postUSDC = await getUSDCBalance();
  const postMackSOL = await getSOLBalance(MACK_PUBKEY);
  const postMackUSDC = await getUSDCBalance(MACK_PUBKEY);
  const deltaSOL = postSOL - preflightSOL;
  const deltaUSDC = postUSDC - preflightUSDC;

  console.log("┌─────────────────────────────────────┐");
  console.log("│        POST-FLIGHT BALANCES          │");
  console.log("├─────────────────────────────────────┤");
  console.log(`│  Alex SOL:  ${postSOL.toFixed(4).padStart(9)} SOL          │`);
  console.log(`│  Alex USDC: $${postUSDC.toFixed(2).padStart(8)}              │`);
  console.log(`│  Mack SOL:  ${postMackSOL.toFixed(4).padStart(9)} SOL          │`);
  console.log(`│  Mack USDC: $${postMackUSDC.toFixed(2).padStart(8)}              │`);
  console.log("├─────────────────────────────────────┤");
  console.log("│           CONSUMPTION                │");
  console.log("├─────────────────────────────────────┤");
  console.log(`│  Alex SOL:  ${deltaSOL.toFixed(4).padStart(9)} SOL          │`);
  console.log(`│  Alex USDC: $${deltaUSDC.toFixed(2).padStart(8)}              │`);
  console.log("└─────────────────────────────────────┘");
});

// ---------------------------------------------------------------------------
// Helper: select the late NFL fixture slate in the contest form
// ---------------------------------------------------------------------------

async function selectE2eSlate(page) {
  await page.selectOption("#contest_slate_id", { label: "NFL 2026 Week 17" });
}

// ---------------------------------------------------------------------------
// Helper: log in via KeypairProvider wallet connect
// ---------------------------------------------------------------------------

async function loginViaKeypair(page) {
  await page.goto("/signin");
  await page.locator('button:has-text("Connect Wallet")').click();
  await page.waitForURL(/^(?!.*signin)/, { timeout: 30000 });
}

// ---------------------------------------------------------------------------
// Helper: log in via passwordless magic link (mirrors e2e/helpers.js login()).
// Email auth is magic-link only now — there is no password form. Mints a token
// through the dev-only /test/magic_link_token endpoint and consumes it.
// ---------------------------------------------------------------------------

async function loginViaEmail(page, email) {
  const resp = await page.request.post("/test/magic_link_token", { data: { email } });
  if (!resp.ok()) {
    throw new Error(`magic_link_token failed: ${resp.status()} ${await resp.text()}`);
  }
  const { url } = await resp.json();
  await page.goto(url);
  await page.waitForURL(
    (u) => !u.pathname.startsWith("/signin") && !u.pathname.startsWith("/magic_link"),
    { timeout: 15000 }
  );
}

// ---------------------------------------------------------------------------
// Helper: select 6 matchup cards
// ---------------------------------------------------------------------------

async function selectMatchups(page, indices) {
  // Default: pick cards 0-5. A number means startIndex for consecutive picks.
  if (indices == null) indices = [0, 1, 2, 3, 4, 5];
  if (typeof indices === "number") {
    const start = indices;
    indices = [0, 1, 2, 3, 4, 5].map((i) => start + i);
  }

  const cards = page.locator("button.bg-surface");

  for (let i = 0; i < indices.length; i++) {
    const blurOverlay = page.locator("div.fixed.inset-0.z-20.cursor-pointer");
    if (await blurOverlay.isVisible({ timeout: 300 }).catch(() => false)) {
      await blurOverlay.click();
    }

    await cards.nth(indices[i]).click();
    await expect(page.locator("body")).toContainText(`${i + 1} / 6`);
  }

  // Wait for all fire-and-forget toggle_selection fetch calls to complete
  // (toggleSelection updates Alpine state immediately but POSTs asynchronously)
  await page.waitForLoadState("networkidle");
}

// ---------------------------------------------------------------------------
// Helper: claim $50 USDC from faucet (user must be logged in)
// ---------------------------------------------------------------------------

async function claimFaucet(page, label, amount = 50) {
  // Wait for EnsureAtaJob to create the token account (runs in Sidekiq after registration)
  await page.waitForTimeout(5000);

  await withDevnetRetry(page, `${label} faucet`, async (pg) => {
    await pg.goto("/faucet");
    await pg.waitForLoadState("networkidle");

    await pg.getByRole("button", { name: `$${amount}`, exact: true }).click();
    await pg.getByRole("button", { name: `Claim $${amount} Test USDC` }).click();

    // Wait for the Solana modal to show success (devnet can be slow)
    await expect(pg.locator("body")).toContainText("Minted", { timeout: 90000 });
  });

  // Close the modal
  await page.locator('button:has-text("Done")').click();
}

// ---------------------------------------------------------------------------
// Helper: confirm entry via direct onchain path (Phantom wallet)
// ---------------------------------------------------------------------------

async function confirmEntryOnchain(page) {
  await withDevnetRetry(page, "confirmEntry (onchain)", async (pg) => {
    await pg.evaluate(async () => {
      const els = document.querySelectorAll("[x-data]");
      for (const el of els) {
        const data = Alpine.$data(el);
        if (typeof data.confirmEntry === "function") {
          await data.confirmEntry();
          return;
        }
      }
      throw new Error("confirmEntry() not found on any Alpine component");
    });

    await expect(pg.locator("body")).toContainText("Entry submitted onchain", {
      timeout: 60000,
    });
  });
}

// ---------------------------------------------------------------------------
// Helper: confirm entry via standard path (managed wallet or non-onchain)
// ---------------------------------------------------------------------------

async function confirmEntryStandard(page) {
  await page.evaluate(async () => {
    const els = document.querySelectorAll("[x-data]");
    for (const el of els) {
      const data = Alpine.$data(el);
      if (typeof data.confirmEntry === "function") {
        await data.confirmEntry();
        return;
      }
    }
    throw new Error("confirmEntry() not found on any Alpine component");
  });

  // Entry may show a Solana modal (managed wallet on onchain contest)
  // or redirect immediately (non-onchain). Handle both cases.
  // No retry — re-calling confirmEntry would fail (cart entry already consumed).
  const doneBtn = page.locator('button:has-text("Done")');
  try {
    await doneBtn.waitFor({ state: "visible", timeout: 15000 });
    await doneBtn.click();
  } catch {
    // No modal — entry redirected directly
  }

  // Wait for the leaderboard to appear after redirect/reload
  await expect(page.locator("body")).toContainText("Leaderboard", { timeout: 30000 });
}

// ---------------------------------------------------------------------------
// Helper: retry a devnet action once on failure
// ---------------------------------------------------------------------------

/**
 * Tries an async action up to 2 times. If the first attempt throws or the
 * `detectFailure` callback returns true, waits `delayMs` then retries.
 *
 * @param {object} page - Playwright page
 * @param {string} label - Human-readable label for console output
 * @param {function} action - async (page, attempt) => void — the action to try
 * @param {object} opts
 * @param {number} opts.delayMs - ms to wait before retry (default 5000)
 */
async function withDevnetRetry(page, label, action, { delayMs = 5000 } = {}) {
  for (let attempt = 1; attempt <= 2; attempt++) {
    try {
      await action(page, attempt);
      return; // success
    } catch (e) {
      if (attempt === 2) throw e;
      console.warn(`${label} — attempt ${attempt} failed: ${e.message.slice(0, 120)}`);
      console.log(`${label} — retrying in ${delayMs}ms...`);
      await page.waitForTimeout(delayMs);
    }
  }
}

// ===========================================================================
// PART 1: Onboarding (register + seed wallets via faucet)
// ===========================================================================

// ===========================================================================
// Test 1: Alex logs in via wallet
// ===========================================================================

test("@devnet 1 — Alex wallet login", async ({
  page,
}) => {
  await setupKeypairProvider(page);

  await loginViaKeypair(page);
  // Filter by hasText so we hit the visible username chip, not the
  // dropdown menu's same-href "Account" link.
  await expect(
    page.locator('a[href="/account"]').filter({ hasText: "alex" }).first()
  ).toBeVisible();
  console.log("Test 1 — Alex logged in via wallet");
});

// ===========================================================================
// Test 2: Alex claims $500 USDC from faucet
// ===========================================================================

test("@devnet 2 — Alex claims $500 USDC from faucet", async ({
  page,
}) => {
  await setupKeypairProvider(page);
  await loginViaKeypair(page);

  await claimFaucet(page, "Test 2", 500);
  console.log("Test 2 — Alex faucet claim successful ($500)");
});

// ===========================================================================
// Test 3: Mason registers via email
// ===========================================================================

test("@devnet 3 — Mason registers via magic link → completes profile", async ({
  page,
}) => {
  const ts = Date.now().toString(36);
  const email = `mason-${ts}@test.com`;

  // Passwordless: a magic link for a brand-new email creates the account and
  // logs in (create-or-login). Mint via the dev-only endpoint + consume — there
  // is no signup password form anymore.
  const resp = await page.request.post("/test/magic_link_token", { data: { email } });
  if (!resp.ok()) {
    throw new Error(`magic_link_token failed: ${resp.status()} ${await resp.text()}`);
  }
  const { url } = await resp.json();
  await page.goto(url);
  await page.waitForURL(
    (u) => !u.pathname.startsWith("/signin") && !u.pathname.startsWith("/magic_link"),
    { timeout: 30000 }
  );

  // Complete profile — a brand-new user has no username, so the
  // profile-completion gate applies.
  await page.goto("/account/complete_profile");
  const username = `mason-${ts}`;
  await page.fill("#user_username", username);
  await page.getByRole("button", { name: "Save Profile" }).click();
  await page.waitForURL(/^(?!.*complete_profile)/, { timeout: 15000 });

  masonEmail = email;

  // Verify on account page
  await page.goto("/account");
  await expect(page.locator("body")).toContainText(username, { timeout: 10000 });
  console.log(`Test 3 — Mason registered (magic link): ${email}`);
});

// ===========================================================================
// Test 4: Mason claims $50 USDC from faucet
// ===========================================================================

test("@devnet 4 — Mason claims $50 USDC from faucet", async ({
  page,
}) => {
  test.skip(!masonEmail, "No Mason credentials from Test 3");

  await loginViaEmail(page, masonEmail);
  console.log(`Test 4 — logged in as ${masonEmail}`);

  await claimFaucet(page, "Test 4");

  // Mason is a fresh user — verify exact $50.00 balance
  await page.goto("/wallet");
  await page.waitForLoadState("networkidle");
  await expect(page.locator("body")).toContainText("$50.00");
  console.log("Test 4 — Mason faucet claim successful, balance $50.00");
});

// ===========================================================================
// Test 5: Mack registers via wallet connect
// ===========================================================================

test("@devnet 5 — Mack wallet connect → complete profile", async ({
  page,
}) => {
  await setupKeypairProvider(page, MACK_KEY);

  // 1. Connect wallet — creates a new user since we cleared Mack's address in beforeAll
  await page.goto("/signin");
  await page.locator('button:has-text("Connect Wallet")').click();

  // May redirect to "/" or "/account/complete_profile" depending on whether profile is complete
  await page.waitForURL(/^(?!.*signin)/, { timeout: 30000 });

  // 2. Complete profile if needed
  if (page.url().includes("complete_profile")) {
    const ts = Date.now().toString(36);
    await page.fill("#user_username", `mack-${ts}`);
    await page.getByRole("button", { name: "Save Profile" }).click();
    await page.waitForURL(/^(?!.*complete_profile)/, { timeout: 15000 });
    console.log("Test 5 — profile completed");
  }

  // 3. Verify logged in — account link should be visible
  await page.goto("/account");
  await expect(page.locator("body")).toContainText(MACK_PUBKEY.slice(0, 8), {
    timeout: 10000,
  });
  console.log(`Test 5 — Mack registered via wallet: ${MACK_PUBKEY}`);
});

// ===========================================================================
// Test 6: Mack claims $50 USDC from faucet
// ===========================================================================

test("@devnet 6 — Mack claims $50 USDC from faucet", async ({
  page,
}) => {
  await setupKeypairProvider(page, MACK_KEY);
  await loginViaKeypair(page);
  console.log("Test 6 — Mack logged in via wallet");

  await claimFaucet(page, "Test 6");
  console.log("Test 6 — Mack faucet claim successful");
});

// ===========================================================================
// PART 2: Small Contest (3-entry, onchain)
// ===========================================================================

// ===========================================================================
// Test 7: Alex creates small (3-entry) onchain contest
// ===========================================================================

test("@devnet 7 — small contest: create 3-entry onchain contest", async ({
  page,
}) => {
  await setupKeypairProvider(page);
  await loginViaKeypair(page);

  const contestName = `Small ${Date.now().toString(36)}`;

  await withDevnetRetry(page, "Test 7 contest create", async (pg) => {
    await pg.goto("/contests/new");
    await pg.fill("#contest_name", contestName);
    await selectE2eSlate(pg);
    // Small format is selected by default — no need to change
    await pg.getByRole("button", { name: "Create Contest" }).click();
    await pg.waitForURL(/\/contests\/(?!new)/, { timeout: 90000 });
    await expect(pg.locator("body")).toContainText(contestName);
  });

  const contestUrl = page.url();
  sharedSmallContestUrl = contestUrl;
  console.log(`Test 7 — created small (3-entry) onchain contest: ${contestUrl}`);
});

// ===========================================================================
// Test 8: Mason enters small contest
// ===========================================================================

test("@devnet 8 — small contest: Mason picks 6 → enters", async ({
  page,
}) => {
  test.skip(!sharedSmallContestUrl, "No shared small contest URL from Test 7");
  test.skip(!masonEmail, "No Mason credentials from Test 3");

  await loginViaEmail(page, masonEmail);
  console.log(`Test 8 — logged in as ${masonEmail}`);

  // Navigate to small contest, pick all LEFT sides of game pairs [1/3]
  // (indices 0,2,4,6,8,10 = left button of each game pair)
  await page.goto(sharedSmallContestUrl);
  await page.waitForLoadState("networkidle");
  await selectMatchups(page, [0, 2, 4, 6, 8, 10]);

  // Managed wallet: standard path → redirect
  await confirmEntryStandard(page);
  console.log("Test 8 — Mason entry submitted (left sides)");
});

// ===========================================================================
// Test 9: Mack enters small contest via direct onchain path
// ===========================================================================

test("@devnet 9 — small contest: Mack picks 6 → enters onchain", async ({
  page,
}) => {
  test.skip(!sharedSmallContestUrl, "No shared small contest URL from Test 7");

  await setupKeypairProvider(page, MACK_KEY);

  // Login via wallet (Mack exists from Test 5)
  await loginViaKeypair(page);
  console.log("Test 9 — Mack logged in via wallet");

  // Navigate to small contest, pick all RIGHT sides of game pairs [2/3]
  // (indices 1,3,5,7,9,11 = right button of each game pair — opposite of Mason)
  await page.goto(sharedSmallContestUrl);
  await page.waitForLoadState("networkidle");
  await selectMatchups(page, [1, 3, 5, 7, 9, 11]);

  // Web3 wallet: confirmEntry() goes through direct onchain path
  await confirmEntryOnchain(page);

  // Verify tx signature link
  const explorerLink = page.locator(
    'a[href*="explorer.solana.com/tx"]'
  ).last();
  await expect(explorerLink).toBeVisible({ timeout: 5000 });

  const href = await explorerLink.getAttribute("href");
  console.log(`Test 9 — Mack entry tx: ${href}`);
});

// ===========================================================================
// Test 10: Alex enters small contest onchain [3/3 — fills contest]
// ===========================================================================

test("@devnet 10 — small contest: Alex picks 6 → enters onchain", async ({
  page,
}) => {
  test.skip(!sharedSmallContestUrl, "No shared small contest URL from Test 7");

  await setupKeypairProvider(page);
  await loginViaKeypair(page);

  // Navigate to small contest, select 6 matchups [3/3 — fills the contest]
  await page.goto(sharedSmallContestUrl);
  await page.waitForLoadState("networkidle");
  await selectMatchups(page);
  await expect(page.locator("body")).toContainText("6 / 6");

  // Submit onchain entry
  await confirmEntryOnchain(page);

  // Verify tx signature link in the success modal
  const explorerLink = page.locator('a[href*="explorer.solana.com/tx"]').last();
  await expect(explorerLink).toBeVisible({ timeout: 5000 });

  const href = await explorerLink.getAttribute("href");
  console.log(`Test 10 — Alex entry tx: ${href}`);
});

// ===========================================================================
// Test 11: Alex locks (closes) the small contest
// ===========================================================================

test("@devnet 11 — small contest: Alex locks contest", async ({
  page,
}) => {
  test.skip(!sharedSmallContestUrl, "No shared small contest URL from Test 7");

  await setupKeypairProvider(page);
  await loginViaKeypair(page);

  await page.goto(sharedSmallContestUrl);
  await page.waitForLoadState("networkidle");

  // Admin action: Lock Contest button (visible when contest is open)
  await page.getByRole("button", { name: "Lock Contest" }).click();

  // Verify the flash notice confirms lock
  await expect(page.locator("body")).toContainText("Contest locked!", { timeout: 15000 });
  console.log("Test 11 — Small contest locked");
});

// ===========================================================================
// Test 12: Alex simulates first game
// ===========================================================================

test("@devnet 12 — small contest: Alex simulates first game", async ({
  page,
}) => {
  test.skip(!sharedSmallContestUrl, "No shared small contest URL from Test 7");

  await setupKeypairProvider(page);
  await loginViaKeypair(page);

  await page.goto(sharedSmallContestUrl);
  await page.waitForLoadState("networkidle");

  // Admin action: Simulate the next pending game (button text is "Simulate: [Home] vs [Away]")
  await page.locator('button:has-text("Simulate:")').first().click();

  // Verify the flash notice confirms simulation with score
  await expect(page.locator("body")).toContainText("Simulated", { timeout: 15000 });
  console.log("Test 12 — First game simulated");
});

// ===========================================================================
// PART 3: Standard Contest (30-entry, multi-entry focus)
// ===========================================================================

// ===========================================================================
// Test 13: Alex creates standard (30-entry) contest
// ===========================================================================

test("@devnet 13 — standard contest: create 30-entry contest", async ({
  page,
}) => {
  await setupKeypairProvider(page);

  // Login as Alex (admin)
  await loginViaKeypair(page);

  // Create standard contest via the form (DB-only — skip onchain signing)
  const contestName = `Standard ${Date.now().toString(36)}`;

  await page.goto("/contests/new");
  await page.waitForLoadState("networkidle");
  await page.fill("#contest_name", contestName);
  await selectE2eSlate(page);

  // Click the Standard format card (second card)
  await page.locator(".cursor-pointer.rounded-lg").filter({ hasText: /standard/i }).click();

  // Submit form data directly to create DB-only contest (skips wallet onchain flow)
  const slug = await page.evaluate(async () => {
    const form = document.getElementById("contest-form");
    const formData = new FormData(form);
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
    const resp = await fetch(form.action, {
      method: "POST",
      headers: { "X-CSRF-Token": csrfToken, Accept: "application/json" },
      body: formData,
    });
    const data = await resp.json();
    if (!data.success) throw new Error(data.error || "Failed to create contest");
    return data.slug;
  });

  sharedStandardContestUrl = `/contests/${slug}`;
  console.log(`Test 13 — created standard (30-entry) contest: ${sharedStandardContestUrl}`);

  // Verify the contest page loads correctly
  await page.goto(sharedStandardContestUrl);
  await page.waitForLoadState("networkidle");
  await expect(page.locator("body")).toContainText(contestName, { timeout: 10000 });
});

// ===========================================================================
// Test 14: Mason 1st entry on standard contest
// ===========================================================================

test("@devnet 14 — standard contest: Mason picks 6 → enters", async ({
  page,
}) => {
  test.skip(!sharedStandardContestUrl, "No shared standard contest URL from Test 13");
  test.skip(!masonEmail, "No Mason credentials from Test 3");

  await loginViaEmail(page, masonEmail);
  console.log(`Test 14 — logged in as ${masonEmail}`);

  // Navigate to standard contest, pick 6 matchups
  await page.goto(sharedStandardContestUrl);
  await page.waitForLoadState("networkidle");
  await selectMatchups(page);

  // Standard path → redirect
  await confirmEntryStandard(page);
  console.log("Test 14 — Mason 1st standard entry submitted");
});

// ===========================================================================
// Test 15: Mason 2nd entry on standard contest (different picks)
// ===========================================================================

test("@devnet 15 — standard contest: Mason re-enters with different picks", async ({
  page,
}) => {
  test.skip(!sharedStandardContestUrl, "No shared standard contest URL from Test 13");
  test.skip(!masonEmail, "No Mason credentials from Test 3");

  await loginViaEmail(page, masonEmail);
  console.log(`Test 15 — logged in as ${masonEmail}`);

  // Navigate to standard contest and clear stale picks
  await page.goto(sharedStandardContestUrl + "?add_entry=true");
  await page.waitForLoadState("networkidle");

  const contestPath = new URL(page.url()).pathname;
  await page.evaluate(async (cp) => {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
    await fetch(`${cp}/clear_picks`, {
      method: "POST",
      headers: { "X-CSRF-Token": csrfToken, "Accept": "application/json" },
    });
  }, contestPath);
  console.log("Test 15 — cleared stale picks");

  // Reload board so pick count resets to 0/6
  await page.goto(sharedStandardContestUrl + "?add_entry=true");
  await page.waitForLoadState("networkidle");

  // Pick different 6 matchups (cards 6-11) to avoid sybil check
  await selectMatchups(page, 6);

  // Standard path → redirect
  await confirmEntryStandard(page);
  console.log("Test 15 — Mason 2nd standard entry submitted");
});

// ===========================================================================
// Test 16: Mack 1st entry on standard contest
// ===========================================================================

test("@devnet 16 — standard contest: Mack picks 6 → enters", async ({
  page,
}) => {
  test.skip(!sharedStandardContestUrl, "No shared standard contest URL from Test 13");

  await setupKeypairProvider(page, MACK_KEY);

  // Login via wallet
  await loginViaKeypair(page);
  console.log("Test 16 — Mack logged in via wallet");

  // Navigate to standard contest, pick 6 matchups
  await page.goto(sharedStandardContestUrl);
  await page.waitForLoadState("networkidle");
  await selectMatchups(page);

  // Standard path (contest is not onchain) → redirect
  await confirmEntryStandard(page);
  console.log("Test 16 — Mack 1st standard entry submitted");
});

// ===========================================================================
// Test 17: Mack 2nd entry on standard contest (different picks)
// ===========================================================================

test("@devnet 17 — standard contest: Mack re-enters with different picks", async ({
  page,
}) => {
  test.skip(!sharedStandardContestUrl, "No shared standard contest URL from Test 13");

  await setupKeypairProvider(page, MACK_KEY);

  // Login via wallet
  await loginViaKeypair(page);
  console.log("Test 17 — Mack logged in via wallet");

  // Navigate to standard contest with add_entry=true for second entry
  await page.goto(sharedStandardContestUrl + "?add_entry=true");
  await page.waitForLoadState("networkidle");

  // Pick different 6 matchups (cards 6-11) to avoid sybil check
  await selectMatchups(page, 6);

  // Standard path → redirect
  await confirmEntryStandard(page);
  console.log("Test 17 — Mack 2nd standard entry submitted");
});
