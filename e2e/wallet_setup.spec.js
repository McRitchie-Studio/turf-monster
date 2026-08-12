const { test, expect } = require("@playwright/test");
const { reseed, setupPhantomMock, MOCK_PUBKEY_B58 } = require("./helpers");

// Web3-only onboarding (ENABLE_WEB3_ONLY_ONBOARDING) — the "Set up your wallet"
// step a brand-new email/Google account lands on now that signup mints no
// custodial wallet.
//
// The two behaviours only a browser can prove:
//   1. auth success AUTO-OPENS the modal, with the Phantom row + the teaching
//      block the operator specified (the markup tiers assert it renders; only
//      here does the Alpine step machine actually run and pick a branch), and
//   2. it is DISMISSIBLE and COMES BACK at the entry gate — the half of the
//      operator's call that lives entirely in client state.
//
// The flag is set on the e2e server (playwright.config.js webServer env), which
// is the configuration this ships in for the NFL season.
test.setTimeout(60_000);

test.beforeEach(async ({ request }) => await reseed(request));

// Sign in a brand-new email through the real magic-link round trip. Under the
// flag this account has NO wallet, which is the state under test.
async function signUpFreshEmail(page) {
  const email = `walletsetup-${Date.now().toString(36)}@example.com`;
  const resp = await page.request.post("/test/magic_link_token", { data: { email } });
  expect(resp.ok()).toBeTruthy();
  const { url } = await resp.json();
  await page.goto(url);
  await page.waitForURL(
    (u) => !u.pathname.startsWith("/signin") && !u.pathname.startsWith("/magic_link")
  );
  return email;
}

// eligibilityBlocker checks the LEGAL gate (DOB, ENABLE_AGE_GATE) before the
// capability gate this spec is about, and that order is deliberate. The age gate
// is off in CI's e2e server but ON in some local stacks' .env, so asserting the
// wallet reason without neutralizing it makes this spec pass or fail on the
// operator's env rather than on the code. Satisfy age in the client store — the
// blocker reads exactly this — so what's left under test is the wallet rung.
async function satisfyAgeGate(page) {
  await page.evaluate(() => {
    const sess = Alpine.store("session");
    if (sess) sess.ageVerified = true;
  });
}

test("a fresh email signup lands on the wallet-setup modal @smoke", async ({ page }) => {
  await signUpFreshEmail(page);

  // Auto-opened by the layout's one-shot session prompt.
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible();

  // The Phantom row. On a headless browser no wallet is injected, so this is
  // the INSTALL branch — the state a brand-new player sees.
  const phantomRow = page.locator('a[href="https://phantom.com/download"]');
  await expect(phantomRow).toBeVisible();
  await expect(phantomRow).toContainText("Phantom");
  await expect(phantomRow).toContainText(/install/i);

  // The teaching block: heading, both screenshots side by side, and the CTA.
  await expect(page.getByText("New to Solana Wallets?")).toBeVisible();
  await expect(page.locator('img[src="/phantom-step-download.png"]')).toBeVisible();
  await expect(page.locator('img[src="/phantom-step-create-wallet.png"]')).toBeVisible();
  await expect(page.getByRole("link", { name: /Read the setup guide/i })).toBeVisible();
});

test("both onboarding screenshots load (not broken images) @smoke", async ({ page }) => {
  await signUpFreshEmail(page);
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible();

  // naturalWidth is 0 for an image the browser failed to fetch — a visibility
  // assertion alone passes on a broken <img>.
  for (const src of ["/phantom-step-download.png", "/phantom-step-create-wallet.png"]) {
    const width = await page.locator(`img[src="${src}"]`).evaluate((img) => img.naturalWidth);
    expect(width, `${src} should decode`).toBeGreaterThan(0);
  }
});

test("the modal is dismissible and does not re-open on navigation @smoke", async ({ page }) => {
  await signUpFreshEmail(page);
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible();

  await page.getByRole("button", { name: "Maybe later" }).click();
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeHidden();

  // One-shot: browsing on must not re-nag.
  await page.goto("/contests");
  await page.waitForLoadState("networkidle");
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeHidden();
});

test("the entry gate brings the wallet-setup modal back", async ({ page }) => {
  await signUpFreshEmail(page);
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible();
  await page.getByRole("button", { name: "Maybe later" }).click();
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeHidden();

  // The client-side gate is what re-opens it: eligibilityBlocker returns
  // wallet_setup_required for a wallet-less session, ahead of every funding
  // check, and the board's dispatcher maps it to this modal. Driving the
  // validation directly avoids the flaky press-and-hold timing (same approach
  // as geo_hold_validation.spec.js).
  await page.goto("/");
  await page.waitForLoadState("networkidle");
  await satisfyAgeGate(page);

  const blocker = await page.evaluate(() =>
    window.eligibilityBlocker(Alpine.store("session"), 1900, { acceptsUsdt: false })
  );
  expect(blocker).not.toBeNull();
  expect(blocker.reason).toBe("wallet_setup_required");

  await page.evaluate(() => {
    const els = document.querySelectorAll("[x-data]");
    for (const el of els) {
      const data = Alpine.$data(el);
      if (typeof data.showWalletSetupModal === "function") return data.showWalletSetupModal();
    }
    throw new Error("showWalletSetupModal not found on any Alpine component");
  });

  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible();
});

// The point of the whole modal: the INSTALL row is the easy branch, and it was
// the only one a headless browser could reach (no wallet is injected). These two
// cover the branch that actually finishes the job.
// seedByte 1 (setupPhantomMock's default) is MOCK_PUBKEY_B58 — the wallet
// e2e/global-setup.js parks on the seeded ADMIN so loginViaPhantom resolves to
// them. Linking it to a fresh account is not a no-op: AccountsController
// #link_solana treats "this wallet belongs to someone else" as a consolidation
// and calls merge_users!, which absorbed the admin into a throwaway signup and
// left global-teardown unable to find them. Any spec that links a wallet to a
// NEW user must therefore bring a wallet nobody owns.
const UNOWNED_WALLET_SEED = 7;

test("with Phantom present the row offers Connect and says what signing does", async ({ page }) => {
  await setupPhantomMock(page, { seedByte: UNOWNED_WALLET_SEED });
  await signUpFreshEmail(page);

  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible();
  await expect(page.getByText("Connect", { exact: true })).toBeVisible();
  await expect(page.getByText(/sign a message to prove the wallet is yours/i)).toBeVisible();
  // The install link is the OTHER branch — it must not be showing.
  await expect(page.locator('a[href="https://phantom.com/download"]')).toBeHidden();
});

test("a wallet that registers AFTER the modal opens still flips to Connect", async ({ page }) => {
  // The bug this pins down: walletProvider.available() is documented "CALL AT
  // CLICK TIME — the list fills in asynchronously as wallets register after
  // module load". This modal auto-opens at page load, mid-handshake, so a single
  // early read is a coin flip — an installed Phantom painted INSTALL and the user
  // was told to install what they already had.
  //
  // Reproduced by registering a wallet a full second AFTER the modal is up, which
  // is later than any single early read could ever catch.
  await signUpFreshEmail(page);
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible();
  await expect(page.locator('a[href="https://phantom.com/download"]')).toBeVisible();

  await page.waitForTimeout(1000);
  await page.evaluate(() => {
    // A minimal Wallet-Standard wallet with the two features the SIWS flow
    // requires, announced the way a late wallet announces itself.
    const wallet = {
      name: "Phantom",
      icon: "data:image/svg+xml;base64,",
      chains: ["solana:mainnet"],
      accounts: [],
      features: {
        "standard:connect": { version: "1.0.0", connect: async () => ({ accounts: [] }) },
        "solana:signMessage": { version: "1.0.0", signMessage: async () => [] },
      },
    };
    window.dispatchEvent(
      new CustomEvent("wallet-standard:register-wallet", {
        detail: (api) => api.register(wallet),
      })
    );
  });

  // No reload, no click: the row must notice on its own.
  await expect(page.getByText("Connect", { exact: true })).toBeVisible({ timeout: 10000 });
  await expect(page.locator('a[href="https://phantom.com/download"]')).toBeHidden();
});

test("Connect links the wallet to the signed-in account and clears the gate", async ({ page }) => {
  await setupPhantomMock(page, { seedByte: UNOWNED_WALLET_SEED });
  await signUpFreshEmail(page);
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible();

  // Real Ed25519 signing (phantom-mock) through the real SIWS round trip, so
  // the server's verify_solana_signature! + /account/link_solana run unstubbed.
  await page.getByText("Connect", { exact: true }).click();

  // A successful link reloads back to where the user was — the returnUrl the
  // modal was opened with — NOT /account.
  await page.waitForFunction(() => {
    const el = document.getElementById("session-context");
    if (!el) return false;
    return JSON.parse(el.textContent).walletSetupRequired === false;
  }, null, { timeout: 20000 });

  // #session-context is SERVER-rendered from the reloaded User row, so these are
  // assertions about what actually persisted — not about client state.
  const ctx = await page.evaluate(() =>
    JSON.parse(document.getElementById("session-context").textContent)
  );
  expect(ctx.loggedIn).toBe(true);
  expect(ctx.phantomLinked).toBe(true);
  expect(ctx.walletSetupRequired).toBe(false);
  expect(ctx.address).toMatch(/^[1-9A-HJ-NP-Za-km-z]{32,44}$/); // base58 pubkey
  expect(ctx.address).not.toBe(MOCK_PUBKEY_B58); // never the seeded admin's wallet

  // The gate is satisfied: the modal is gone and does not come back at entry.
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeHidden();
  const blocker = await page.evaluate(() =>
    window.eligibilityBlocker(
      Object.assign({}, Alpine.store("session"), { ageVerified: true }),
      1900,
      { acceptsUsdt: false }
    )
  );
  expect(blocker && blocker.reason).not.toBe("wallet_setup_required");
});

test("the free-contest path is gated too (entry is on-chain either way)", async ({ page }) => {
  await signUpFreshEmail(page);
  await page.goto("/");
  await page.waitForLoadState("networkidle");
  await satisfyAgeGate(page);

  // neededCents 0 = a free contest. The wallet check sits BEFORE that
  // short-circuit on purpose: a wallet-less account can't sign a free entry.
  const blocker = await page.evaluate(() =>
    window.eligibilityBlocker(Alpine.store("session"), 0, { acceptsUsdt: false })
  );
  expect(blocker).not.toBeNull();
  expect(blocker.reason).toBe("wallet_setup_required");
});
