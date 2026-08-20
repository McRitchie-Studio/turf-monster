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

// Sign in a brand-new email through the real magic-link round trip, then WALK
// THE ONBOARDING CHAIN to the wallet step.
//
// The wallet modal is no longer the first thing a signup sees: since the
// post-auth chain landed (2026-08-12) reaching it means answering the steps
// ahead of it. The order is first name → age → wallet as of 2026-08-15, when the
// welcome card was retired.
// These specs are about the wallet card itself, not about how it is reached
// (e2e/onboarding_chain.spec.js owns the order), so the walk lives in the helper
// and each spec below starts where it always did.
async function signUpFreshEmail(page) {
  const email = `walletsetup-${Date.now().toString(36)}@example.com`;
  const resp = await page.request.post("/test/magic_link_token", { data: { email } });
  expect(resp.ok()).toBeTruthy();
  const { url } = await resp.json();
  await page.goto(url);
  await page.waitForURL(
    (u) => !u.pathname.startsWith("/signin") && !u.pathname.startsWith("/magic_link")
  );

  // NOTE on the waits below: locator.isVisible() does NOT wait — it answers for
  // the DOM as it stands right now and ignores a timeout option. Using it to
  // decide whether to click races each step's advance animation, which is
  // exactly how an earlier version of this helper silently stopped on the
  // first-name step and every spec here failed at the final assertion. Wait
  // explicitly with waitFor(), and treat a timeout as "that step isn't in the
  // chain" (the flags could legitimately drop the age step).
  const appears = async (locator, ms = 10000) =>
    await locator
      .waitFor({ state: "visible", timeout: ms })
      .then(() => true)
      .catch(() => false);

  // Step 1 — first name, the chain's opening card. Skipped: these specs are not
  // about it, and skipping is the path that must still reach the wallet.
  const skip = page.getByRole("button", { name: "Skip for now" });
  if (await appears(skip)) await skip.click();

  // Step 2 — the DOB gate (ENABLE_AGE_GATE is on for this lane).
  const ageHeading = page.getByRole("heading", { name: /Verify your age/i });
  if (await appears(ageHeading)) {
    await page.evaluate(() => {
      const els = document.querySelectorAll("[x-data]");
      for (const el of els) {
        const d = Alpine.$data(el);
        if (d && "year" in d && "month" in d && "day" in d) {
          d.year = "1990"; d.month = "6"; d.day = "15";
          return;
        }
      }
    });
    await page.getByRole("button", { name: /Confirm & Continue/i }).click();
  }

  // Step 3 — the wallet card these specs are about.
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible({ timeout: 20000 });
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

// The first-name gate sits AHEAD of the wallet gate in eligibilityBlocker since
// 2026-08-15, and the helper above skips the name rather than saving it — so
// without this every blocker assertion in this file would read
// first_name_required and never reach its own subject. Same shape as
// satisfyAgeGate: settle the store field the synchronous blocker reads, so the
// spec stays about the WALLET.
async function satisfyFirstNameGate(page) {
  await page.evaluate(() => {
    const sess = Alpine.store("session");
    if (sess) sess.firstNameRequired = false;
  });
}

test("the wallet step renders the Phantom row and the teaching block @smoke", async ({ page }) => {
  // The helper walks the chain and already asserts the card is up.
  await signUpFreshEmail(page);

  // The Phantom row. On a headless browser no wallet is injected, so this is
  // the INSTALL branch — the state a brand-new player sees.
  const phantomRow = page.locator('a[href="https://phantom.com/download"]');
  await expect(phantomRow).toBeVisible();
  await expect(phantomRow).toContainText("Phantom");
  await expect(phantomRow).toContainText(/install/i);
  // Not waiting yet — the spinner only appears once they leave to install.
  await expect(phantomRow.locator(".cta-spinner")).toBeHidden();

  // The teaching block: heading, the player (already running, muted), the
  // unmute affordance, and the CTA.
  await expect(page.getByRole("heading", { name: /New to Solana/ })).toBeVisible();
  await expect(page.locator('iframe[src*="youtube-nocookie.com/embed"]')).toHaveCount(1);
  await expect(page.getByRole("button", { name: /Unmute the video/i })).toBeVisible();
  await expect(page.getByRole("link", { name: /Detailed Guide/i })).toBeVisible();
});

test("the video starts itself, muted, and one click buys sound @smoke", async ({ page }) => {
  await signUpFreshEmail(page);
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible();

  // It is already playing when the card lands — no poster, no play button.
  // Muted is not a preference: it is the only autoplay a browser permits on a
  // modal that opened without a click, so the two ship as one thing.
  const player = page.locator('iframe[src*="youtube-nocookie.com/embed"]');
  await expect(player).toHaveCount(1);
  const src = await player.getAttribute("src");
  expect(src, "autoplay alone is blocked outright").toContain("autoplay=1");
  expect(src, "...so mute travels with it").toContain("mute=1");
  expect(src, "the unmute click reaches the player over the JS API").toContain("enablejsapi=1");

  // The affordance covers the whole player on purpose: while the video is
  // silent, a click landing on the player itself would PAUSE it.
  const unmute = page.getByRole("button", { name: /Unmute the video/i });
  await expect(unmute).toBeVisible();
  await expect(page.getByText("Tap for sound")).toBeVisible();
  // A ratio, not exact pixels: the container's 1px border and sub-pixel layout
  // leave the overlay a couple of tenths narrower than the iframe, and the
  // claim under test is not "identical box" — it is "covers the player rather
  // than sitting in a corner", which a corner chip would fail at ~0.3.
  const box = await unmute.boundingBox();
  const frameBox = await player.boundingBox();
  expect(box.width / frameBox.width, "the overlay must cover the player").toBeGreaterThan(0.98);
  expect(box.height / frameBox.height, "the overlay must cover the player").toBeGreaterThan(0.98);

  // One click, and it hands the player's own controls back for good.
  await unmute.click();
  await expect(unmute).toBeHidden();

  // The modal is still open around it — the whole point is not leaving.
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible();
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
  await satisfyFirstNameGate(page);

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
// the only one a headless browser could reach (no wallet is injected). The specs
// below cover the branch that actually finishes the job.
//
// seedByte 1 (setupPhantomMock's default) is MOCK_PUBKEY_B58 — the wallet
// e2e/global-setup.js parks on the seeded ADMIN so loginViaPhantom resolves to
// them. Linking it to a fresh account is not a no-op: AccountsController
// #link_solana treats "this wallet belongs to someone else" as a consolidation
// and calls merge_users!, which absorbed the admin into a throwaway signup and
// left global-teardown unable to find them. Any spec that links a wallet to a
// NEW user must therefore bring a wallet nobody owns.
const UNOWNED_WALLET_SEED = 7;

test("with Phantom present the row shows Installed and says what signing does", async ({ page }) => {
  await setupPhantomMock(page, { seedByte: UNOWNED_WALLET_SEED });
  await signUpFreshEmail(page);

  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible();
  await expect(page.getByText("Installed", { exact: true })).toBeVisible();
  // Fragment kept inside one source line — the copy wraps in the ERB, so a
  // regex spanning the wrap would depend on how whitespace survives rendering.
  await expect(page.getByText(/sign a message proving/i)).toBeVisible();
  // The install link is the OTHER branch — it must not be showing.
  await expect(page.locator('a[href="https://phantom.com/download"]')).toBeHidden();
});

test("leaving to install puts the row in a waiting state that watches, not reloads", async ({ page }) => {
  // The operator's design: no instruction to follow. Clicking Install arms a
  // spinner, and the row updates on its own — via the 1s ping when the provider
  // can appear in THIS document, and via a hidden probe frame when it cannot
  // (Chrome injects a new extension only into documents created after the
  // install, so this tab will never have one).
  //
  // What this test pins is the half the operator asked for on 2026-08-18: the
  // page they are reading does not move.
  await signUpFreshEmail(page);
  const row = page.locator('a[href="https://phantom.com/download"]');
  await expect(row).toBeVisible();

  // A witness that lives ONLY in this document. It survives anything except a
  // navigation, which makes it the cheapest possible proof that none happened.
  await page.evaluate(() => { window.__walletProbeWitness = "alive"; });

  const [installTab] = await Promise.all([
    page.context().waitForEvent("page").catch(() => null),
    row.click(),
  ]);
  if (installTab) await installTab.close().catch(() => {});

  // Waiting state: spinner + Waiting…, and NO instruction to press anything.
  await expect(row.locator(".cta-spinner")).toBeVisible();
  await expect(row).toContainText(/waiting/i);
  await expect(page.getByText(/Finish downloading the Phantom wallet extension/i)).toBeVisible();
  await expect(page.getByText("Reload page")).toBeHidden();

  // The probe frame really loads OUR probe page. This is the assertion that
  // covers the CSP exemption end to end: the app forbids being framed
  // (frame-ancestors 'none') and WalletProbeController relaxes that to 'self'
  // for this one page. Get that wrong and the frame is silently refused, the
  // row waits forever, and nothing anywhere reports an error.
  await expect
    .poll(
      async () =>
        await page.evaluate(() => {
          const f = document.querySelector('iframe[title="Phantom detection"]');
          if (!f) return "no-frame";
          try {
            return (f.contentDocument && f.contentDocument.title) || "unreadable";
          } catch (e) {
            return "blocked";
          }
        }),
      { timeout: 15000, message: "the probe frame must load the same-origin probe page" }
    )
    .toBe("wallet probe");

  // Coming back to the tab re-pokes the probe — and moves nothing else. The
  // modal is still up because it was never torn down, not because it was
  // rebuilt after a reload.
  await page.evaluate(() => document.dispatchEvent(new Event("visibilitychange")));
  await page.waitForTimeout(2500);
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible();

  expect(
    await page.evaluate(() => window.__walletProbeWitness),
    "the page must not have reloaded"
  ).toBe("alive");
  // The retired mechanism must not come back under any name.
  expect(await page.evaluate(() => sessionStorage.getItem("walletSetupAutoReloaded"))).toBeNull();
});

test("a Phantom installed after this tab opened flips the row in place", async ({ page }) => {
  // THE CASE THE WHOLE PROBE EXISTS FOR, and the one no amount of polling can
  // reach: the tab was open before the install, so this document has no
  // provider and never will. A document created AFTER the install does.
  //
  // Simulated exactly that way — the page keeps no Phantom, and only NEW
  // /wallet_probe documents have one. Fulfilling the route is the one honest
  // way to draw that line in a browser we cannot install an extension into.
  await signUpFreshEmail(page);
  const row = page.locator('a[href="https://phantom.com/download"]');
  await expect(row).toBeVisible();

  await page.evaluate(() => { window.__walletProbeWitness = "alive"; });

  await page.route("**/wallet_probe*", (route) =>
    route.fulfill({
      status: 200,
      contentType: "text/html",
      body:
        "<!DOCTYPE html><html><head><title>wallet probe</title>" +
        "<script>window.phantom = { solana: { isPhantom: true } };</script>" +
        "</head><body></body></html>",
    })
  );

  const [installTab] = await Promise.all([
    page.context().waitForEvent("page").catch(() => null),
    row.click(),
  ]);
  if (installTab) await installTab.close().catch(() => {});

  // The row flips itself. No reload, no click, no instruction.
  await expect(page.getByText("Installed", { exact: true })).toBeVisible({ timeout: 20000 });
  await expect(row).toBeHidden();

  // ...and the page underneath is the same page it always was.
  expect(
    await page.evaluate(() => window.__walletProbeWitness),
    "detecting Phantom must not reload the page"
  ).toBe("alive");

  // The effects swap with the state: the glow ring was the install row's TARGET
  // marker and leaves with it; the connect row pulses instead.
  const connectRow = page.locator("button.pulse-cta");
  await expect(connectRow).toBeVisible();
  await expect(page.locator("a.studio-team-glow")).toHaveCount(0);

  // Clicking it hands the intent across the one reload that IS needed — this
  // document still cannot reach Phantom, so it cannot sign here.
  await connectRow.click();
  await page.waitForLoadState("load");
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible({
    timeout: 15000,
  });
  // Both keys are spent on arrival, so nothing replays later.
  expect(await page.evaluate(() => sessionStorage.getItem("walletSetupAutoConnect"))).toBeNull();
  expect(await page.evaluate(() => sessionStorage.getItem("walletSetupReopen"))).toBeNull();
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

  // No reload, no click: the row must notice on its own and flip to Installed.
  await expect(page.getByText("Installed", { exact: true })).toBeVisible({ timeout: 10000 });
  await expect(page.locator('a[href="https://phantom.com/download"]')).toBeHidden();
});

test("Connect links the wallet to the signed-in account and clears the gate", async ({ page }) => {
  await setupPhantomMock(page, { seedByte: UNOWNED_WALLET_SEED });
  await signUpFreshEmail(page);
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible();

  // Real Ed25519 signing (phantom-mock) through the real SIWS round trip, so
  // the server's verify_solana_signature! + /account/link_solana run unstubbed.
  await page.getByText("Installed", { exact: true }).click();

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
  await satisfyFirstNameGate(page);

  // neededCents 0 = a free contest. The wallet check sits BEFORE that
  // short-circuit on purpose: a wallet-less account can't sign a free entry.
  const blocker = await page.evaluate(() =>
    window.eligibilityBlocker(Alpine.store("session"), 0, { acceptsUsdt: false })
  );
  expect(blocker).not.toBeNull();
  expect(blocker.reason).toBe("wallet_setup_required");
});
