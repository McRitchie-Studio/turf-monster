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

test("losing the signer greys the check and leaves the session intact", async ({ page }) => {
  await setupPhantomMock(page, { walletStandard: false });
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
