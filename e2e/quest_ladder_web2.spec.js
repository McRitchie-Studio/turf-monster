// Quest ladder — web2 (email / managed-wallet) user, driven on the contest page.
//
// Same client step machine as quest_ladder_web3, but the user signs in with a
// magic link, so they already have an email on file, and we then hand them a
// managed wallet.
//
// That second half USED to be free: User#generate_managed_wallet! ran
// after_create for every non-admin. Web3-only onboarding
// (ENABLE_WEB3_ONLY_ONBOARDING — no custodial wallet at signup) ended that, so
// this spec now grants the wallet explicitly via grantManagedWallet(). The
// audience it covers is the GRANDFATHERED web2 user, who still exists and is
// still supported — the flag changed who gets MINTED a wallet, not who is
// served. Without the explicit grant the user has no wallet, the username modal
// renders the non-managed copy, and this spec fails on a premise it no longer
// gets for free.
//
// The two web2 divergences this spec pins down:
//   1. The username modal renders the managed-wallet copy and the custodial
//      save path (still on-chain server-side — stubbed; see stubQuestEndpoints).
//   2. The newsletter quest is ONE-CLICK: with an email already on file,
//      questNewsletter.start() joins immediately — NO add-email capture modal —
//      and the card crossfades straight to the invite step.
//
// CHAINLESS NOTE: see quest_ladder_web3.spec.js — the on-chain seed grants don't
// fire for off-chain e2e contests, so we stub the three quest endpoints and
// assert UI flow only.

const { test, expect } = require("@playwright/test");
const {
  login,
  reseed,
  createActiveEntry,
  grantManagedWallet,
  stubQuestEndpoints,
} = require("./helpers");

const CONTEST_SLUG = "world-cup-2026";
const CONTEST_PATH = `/contests/${CONTEST_SLUG}`;

test.beforeEach(async ({ request }) => await reseed(request));

test("web2 user climbs the full quest ladder on the contest page", async ({ page }) => {
  test.setTimeout(60_000);

  // A fresh email → magic-link consume creates the account: email on file, auto
  // username, fresh quest state → quest_step starts at :username. The managed
  // wallet is then granted explicitly (see the header) so solana_connected? /
  // can_change_username? unlock with an entry — this is the grandfathered web2
  // user, not a brand-new signup, which no longer gets a custodial wallet.
  const email = `quest-web2-${Date.now().toString(36)}@mcritchie.studio`;
  await login(page, email);
  await grantManagedWallet(page);

  await createActiveEntry(page, CONTEST_SLUG);
  await stubQuestEndpoints(page);
  await page.goto(CONTEST_PATH);

  const dialog = page.getByRole("dialog");

  // --- Mission 1: change username -----------------------------------------
  await expect(page.getByText("Change Your Username")).toBeVisible();
  await page.getByRole("button", { name: "Change Username" }).click();
  await expect(dialog.getByText("via your managed wallet")).toBeVisible(); // web2 copy
  await dialog.getByPlaceholder("username").fill("quest-web2-hero");
  await dialog.getByRole("button", { name: "Save" }).click();

  // --- Mission 2: send first chat message ----------------------------------
  await expect(page.getByText("Send Your First Message")).toBeVisible();
  const chatInput = page.locator("#contest-chat-input");
  await chatInput.fill("Hi all 👋");
  await chatInput.press("Control+Enter");
  await expect(page.locator(".quest-arrow-spinner")).toBeVisible();
  await expect(page.locator('[aria-label="Sent"]')).toBeVisible();

  // --- Mission 3: join newsletter (ONE-CLICK — no add-email modal) ----------
  await expect(page.getByText("Join the Newsletter")).toBeVisible();
  await page.getByRole("button", { name: "Subscribe" }).click();
  // web2 already has an email → the email-capture modal must NOT appear.
  await expect(page.getByText("One more thing")).toHaveCount(0);

  // --- Mission 4: invite (card crossfaded newsletter -> invite) -------------
  await expect(page.getByRole("button", { name: "Copy Link" })).toBeVisible();
});
