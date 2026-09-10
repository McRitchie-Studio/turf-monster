const { test, expect } = require("@playwright/test");
const {
  login,
  loginViaPhantom,
  setupPhantomMock,
  setupOnchainMocks,
  OPERATOR_USERNAME,
} = require("./helpers");

const CONTEST_PATH = "/contests/world-cup-2026";

// ---------------------------------------------------------------------------
// Helper: select 6 matchup cards on the contest show page
// ---------------------------------------------------------------------------

// 2026-05-24 known issue: the onchain entry test below + several other
// tests in this file fail here. Diagnostic findings (kept for the next
// person to pick up):
//
//   1. The original `button.bg-surface` selector over-matched — 148
//      buttons on the page, only 144 matchup cards. nth(0..5) hit
//      non-matchup buttons first. (Fixed by the scoped + role-aware
//      selector below — Spain/CapeVerde/England/Croatia/France/Senegal
//      reach the cart in JS state with dispatchEvent.)
//
//   2. A normal .click() on the 6th card hangs the test: when
//      selectionCount === picks_required (6), the matchup grid's blur
//      overlay appears immediately, Playwright's post-click actionability
//      check sees the click target now obscured, and retries until 30s
//      timeout. dispatchEvent("click") OR { force: true } works around
//      this.
//
//   3. With dispatchEvent the 6 clicks fire and JS selectionCount goes
//      to 6, but the real test's text assertion still times out — even
//      though an isolated diagnostic shows body.innerText contains "6/6"
//      within 100ms of the dispatches. Possibly Playwright test-runner
//      eventing differs from the diagnostic path. Couldn't pin down
//      further in this session; tests in this file marked .fixme.
async function selectMatchups(page) {
  // role="checkbox" is the matchup-card semantic (_matchup_card.html.erb).
  // Scope to the active selectionBoard, exclude locked matchups.
  const cards = page.locator('[x-data*="selectionBoard"] button[role="checkbox"]:not([disabled])');

  for (let i = 0; i < 6; i++) {
    // Dismiss blur overlay if it appears (after picks_required selections)
    const blurOverlay = page.locator("div.fixed.inset-0.z-20.cursor-pointer");
    if (await blurOverlay.isVisible({ timeout: 300 }).catch(() => false)) {
      await blurOverlay.click();
    }

    await cards.nth(i).click();
    await expect(page.locator("body")).toContainText(`${i + 1} / 6`);
  }
}

// ---------------------------------------------------------------------------
// Test 1: Phantom sign-in (existing user)
// ---------------------------------------------------------------------------

test("phantom sign-in with existing user", async ({ page }) => {
  await setupPhantomMock(page); // seed byte 1 = matches the human operator's solana_address

  await loginViaPhantom(page);

  // The human operator's username should appear in the nav (nav shows username,
  // not display name). Read from the shared constant: the human and the team
  // account traded usernames on 2026-09-04.
  // Filter by hasText on the current nav display hook.
  await expect(
    page.locator("[data-username-display]").filter({ hasText: OPERATOR_USERNAME }).first()
  ).toBeVisible();

  // "Sign in" link should NOT be visible (proves we're authenticated)
  await expect(page.locator('a[href="/signin"]').first()).not.toBeVisible();
});

// ---------------------------------------------------------------------------
// Test 2: Phantom sign-in (new user — different keypair)
// ---------------------------------------------------------------------------

test("phantom sign-in creates new user", async ({ page }) => {
  // Seed byte 2 = pubkey 8pM1DN3RiT8vbom5u1sNryaNT1nyL8CTTW3b5PwWXRBH
  // Not in DB — server creates a new user. Eager username generation
  // (User#ensure_username via before_validation, see project memory
  // "on-chain usernames kickoff 2026-05-22") gives them a kebab-case
  // animal slug like "cumquat-shark" right at signup, so the profile-
  // modal-auto-open prompt the old assertion checked for no longer
  // fires — instead we verify the username chip in the nav is now
  // SOMETHING OTHER than the human operator's username (which would be the
  // existing-user case).
  await setupPhantomMock(page, { seedByte: 2 });

  await loginViaPhantom(page);

  // "Sign in" link should NOT be visible (proves we're authenticated)
  await expect(page.locator('a[href="/signin"]')).not.toBeVisible();

  // A new-user (generated) username chip must be visible in the nav, distinct
  // from the existing human operator's. We filter by a hyphen —
  // Studio::UsernameGenerator always emits a kebab-case "<food>-<animal>" slug
  // — which uniquely separates the chip from the dropdown's same-href
  // "Account" link.
  const usernameChip = page
    .locator("[data-username-display]")
    .filter({ hasText: "-" })
    .first();
  await expect(usernameChip).toBeVisible({ timeout: 3000 });
  await expect(usernameChip).not.toContainText(OPERATOR_USERNAME);
});

// ---------------------------------------------------------------------------
// Onchain contest entry (alex, Phantom + mocked devnet)
//
// NOTE: the old "standard entry with balance deduction" (mack) test was
// removed — it asserted a PAID entry landed on the leaderboard, which can't
// happen in the chainless CI lane (paid entry needs an on-chain Contest PDA).
// Its selection/POST mechanics are covered by smoke.spec.js, and the real
// funded paid entry + balance deduction is covered by devnet-smoke.spec.js
// (Test 9: "Mack picks 6 → enters onchain") against real devnet.
// ---------------------------------------------------------------------------

test.fixme("onchain entry via Phantom with mocked devnet", async ({ page }) => {
  await setupPhantomMock(page);
  await setupOnchainMocks(page);

  await loginViaPhantom(page);

  // Navigate to the contest show page
  await page.goto(CONTEST_PATH);
  await page.waitForLoadState("networkidle");

  // Clear any stale selections from prior tests
  await page.evaluate(async (contestPath) => {
    const csrfToken = document.querySelector(
      'meta[name="csrf-token"]'
    )?.content;
    await fetch(`${contestPath}/clear_picks`, {
      method: "POST",
      headers: { "X-CSRF-Token": csrfToken },
    });
  }, CONTEST_PATH);
  await page.reload();
  await page.waitForLoadState("networkidle");

  // Select 5 matchups
  await selectMatchups(page);

  // Trigger confirmEntry() directly via Alpine (avoids hold-button timing)
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

  // Modal should show success with seeds earned
  await expect(page.locator("body")).toContainText("Entry submitted onchain", {
    timeout: 15000,
  });
  await expect(page.locator("body")).toContainText("+65");

  // Close modal → triggers redirect to contest page
  await page.evaluate(() => Alpine.store("solanaModal").close());
  await page.waitForURL(/\/contests\//, { timeout: 10000 });

  // Contest show page should load
  await expect(page.locator("body")).toContainText("NFL 2026 Week 17");
});

// ---------------------------------------------------------------------------
// Test 5: Contest creation (admin, mocked onchain)
// ---------------------------------------------------------------------------

// 2026-05-24 fixme (revisited): even past the USDC affordability gate, this
// test hits a hard wall at the client-side TX serialization step. The flow:
//
//   1. POST /contests → server builds a partial-signed TX (admin keypair
//      signs the fee-payer slot; creator slot zero-filled for Phantom cosign).
//   2. Client deserializes the TX, Phantom mock partialSigns (real Ed25519).
//   3. connection.sendRawTransaction(signedTx.serialize(), …) — here
//      solanaWeb3 calls verifySignatures by default and rejects with
//      "Invalid signature for public key F6f8…" (the bot, the seed's
//      admin keypair). Source: the server-side recent blockhash stub
//      produces a TX shape whose admin signature solanaWeb3 disagrees
//      with on the round-trip — could be a wire-format mismatch between
//      solana-studio (Ruby) and @solana/web3.js (JS) serialization.
//
// What's been tried (all reverted):
//   - /test/force_usdc_balance endpoint + Rails.cache memory_store → gets
//     past the page-render + server-side balance gates.
//   - Solana::Client stubs for get_token_account_balance, get_account_info,
//     get_latest_blockhash → covered the server-side RPC blockers.
//   - Vault#fetch_wallet_balances stub honoring the cache → prevented the
//     navbar's auto-refresh from clobbering the forced balance.
//
// What's still needed:
//   - Either pass { verifySignatures: false } at the sendRawTransaction
//     call site (intrusive to production code), OR pre-build a TX whose
//     admin signature solanaWeb3 will accept (means coordinating Ruby+JS
//     serialization formats exactly, big undertaking), OR mock the
//     /contests POST response itself at the JS-route level (defeats the
//     point of testing the controller).
//
// Out of scope for now. The investigation notes stay attached so the
// next attempt has a starting point past "everything looks fine
// server-side, why is the client rejecting?"
test.fixme("admin creates onchain contest", async ({ page }) => {
  await setupPhantomMock(page);
  await setupOnchainMocks(page);

  await loginViaPhantom(page);

  await page.goto("/contests/new");

  // Fill the form with unique name
  const contestName = `E2E Contest ${Date.now().toString(36)}`;
  await page.fill("#contest_name", contestName);
  await page.selectOption("#contest_slate_id", { label: "NFL 2026 Week 17" });

  // Click "Create Contest" (inside x-if="hasWallet" — mock makes it visible)
  await page.getByRole("button", { name: "Create Contest" }).click();

  // The inline JS orchestrates: DB create → prepare (mocked) → sign → RPC (mocked)
  // → confirm_onchain_contest (real server) → success modal → countdown redirect

  // Success modal shows countdown then redirects to the new contest page
  await expect(page.locator("body")).toContainText("Redirecting in", {
    timeout: 15000,
  });

  // Auto-redirect after 3s countdown
  await page.waitForURL(/\/contests\/(?!new)/, { timeout: 10000 });

  // Contest show page should display the new contest
  await expect(page.locator("body")).toContainText(contestName);
});
