const { test, expect } = require("@playwright/test");
const { loginViaPhantom, reseed } = require("./helpers");
const { setupPhantomMock } = require("./phantom-mock");

test.beforeEach(async ({ request }) => await reseed(request));

// DEFECT A + B, together — they are one fix.
//
// The green check on /account rendered `user.solana_connected?`, a DATABASE row
// meaning "an address is stored on this account". It said nothing about whether
// the browser could sign, so it stayed lit over a Phantom that was gone. And
// Phantom emits accountChanged ONLY to sites it is connected to, so the app
// could show a confident check while the switch reflex was structurally unable
// to fire. That combination cost a full debugging round: the feature worked and
// looked broken.
//
// Splitting the fix was never an option — the indicator needs a live signal,
// and the disconnect IS that signal.

// WALLET STANDARD, deliberately, and it is the half that had NO browser coverage.
// Both tests in this file used to pin walletStandard: false, so the adapter that a
// modern Phantom actually installs — the one the app swaps to on
// 'wallet-provider:registered' — was never exercised here at all. The sibling test
// below keeps the legacy shape, so the file covers both.
//
// Repointed rather than duplicated: adding a case would change total_specs in
// config/e2e_lane.yml, which turf PR #439 is editing, and two branches writing that
// counter is the exact collision #439 exists to stop.
test("losing the signer greys the check and leaves the session intact", async ({ page }) => {
  await setupPhantomMock(page, { walletStandard: true });
  await loginViaPhantom(page);

  await page.goto("/account");
  const check = page.locator("[data-wallet-live-check]").first();
  await expect(check).toBeVisible();

  // LIVE — a provider is present, unlocked, connected, and on the linked wallet.
  await expect.poll(async () =>
    page.evaluate(() => Alpine.store("wallet")?.state)
  ).toBe("live");
  await expect(check).toHaveClass(/text-green-400/);

  const userIdBefore = await page.locator("body").getAttribute("data-user-id");

  // WAIT FOR THE CHANNEL THE DISCONNECT WILL USE. This is the precondition this
  // test's own header claims — "WALLET STANDARD, deliberately" — and until
  // 2026-08-27 it was never actually established, only hoped for.
  //
  // `state === "live"` above does NOT imply it. Live is reachable on the LEGACY
  // provider, which is what the store watches until the Wallet Standard adapter
  // registers and `wallet-provider:registered` swaps it. The mock's disconnect
  // notifies the Wallet Standard change channel and ONLY that channel, so a
  // disconnect sent before the swap lands in an empty listener array — not
  // queued, not retried, gone — and the poll below then spends its full 5s
  // waiting for an event that will never be sent again.
  //
  // That is the whole flake: locally the swap always won, on CI it did not, and
  // the failure named the assertion instead of the race. Measured 2026-08-27 by
  // widening the mock's registration delay — the CI failure reproduces on demand,
  // `Expected: "degraded" / Received: "live"`.
  await expect
    .poll(() => page.evaluate(() => window.__phantomMockWsChangeSubscribers?.() ?? 0))
    .toBeGreaterThan(0);

  // The extension is disconnected / locked / uninstalled.
  await page.evaluate(() => window.phantom.solana.disconnect());

  // DEGRADED, not broken. The check must stop claiming a signer that is gone.
  await expect.poll(async () =>
    page.evaluate(() => Alpine.store("wallet")?.state)
  ).toBe("degraded");
  await expect(check).not.toHaveClass(/text-green-400/);

  // THE SESSION SURVIVES. Losing the browser signer does not invalidate a
  // signed Rails session, and logging the user out here would be the wrong
  // answer to a wallet that is merely absent.
  await expect(page).not.toHaveURL(/\/signin/);
  expect(await page.locator("body").getAttribute("data-user-id")).toBe(userIdBefore);

  // READ-ONLY, NOT BLANK. Balances are read server-side BY ADDRESS and need no
  // signature, so the wallet tiles must still be on the page.
  await expect(page.locator("[data-wallet-tile='usdc']").first()).toBeVisible();

  // A lost signer is not a wallet SWITCH — the blocking handoff must NOT open.
  // Its only CTA asks the user to sign, on a provider that cannot answer.
  expect(
    await page.evaluate(() => {
      try { return Alpine.store("modals").isOpen("wallet-changed"); }
      catch (e) { return false; }
    })
  ).toBe(false);
});

// DEFECT C — the case the brief called out as untested, and predicted would be
// silent. Phantom disconnects the site outright when the user selects an account
// that has never approved it, which arrives as a null accountChanged. Before
// this slice `_handleAccountChanged` opened with `if (!publicKey) return;`, so
// the app's answer was nothing at all.
test("switching to a never-connected Phantom account degrades instead of going silent", async ({ page }) => {
  await setupPhantomMock(page, { walletStandard: false });
  await loginViaPhantom(page);

  await page.goto("/account");
  await expect.poll(async () =>
    page.evaluate(() => Alpine.store("wallet")?.state)
  ).toBe("live");

  const userIdBefore = await page.locator("body").getAttribute("data-user-id");

  await page.evaluate(() => window.phantom.solana.__switchToUnapprovedAccount());

  await expect.poll(async () =>
    page.evaluate(() => Alpine.store("wallet")?.state)
  ).toBe("degraded");

  // The signer's address is CLEARED, not left stale. A last-known pubkey
  // surviving the loss is the same disease as the green check itself.
  expect(await page.evaluate(() => Alpine.store("wallet")?.signerAddress)).toBeNull();

  await expect(page).not.toHaveURL(/\/signin/);
  expect(await page.locator("body").getAttribute("data-user-id")).toBe(userIdBefore);
});
