const { test, expect } = require("@playwright/test");
const { loginViaPhantom, reseed } = require("./helpers");
const { setupPhantomMock } = require("./phantom-mock");

test.beforeEach(async ({ request }) => await reseed(request));

test("changing Phantom accounts starts a deliberate signed session handoff", async ({ page }) => {
  await setupPhantomMock(page, { walletStandard: true });
  await loginViaPhantom(page);

  const originalUserId = await page.locator("body").getAttribute("data-user-id");
  await page.evaluate(() => Alpine.store("modals").open("onboarding", {}));
  await expect(page.getByRole("dialog")).toContainText("What should we call you?");

  // WAIT FOR THE CHANNEL THIS SWITCH WILL USE — the same precondition
  // e2e/wallet_disconnect.spec.js establishes, for the same reason. Under
  // walletStandard, __switchAccount notifies standardChangeListeners and ONLY
  // that channel, so a switch sent before the Wallet Standard adapter registers
  // lands in an empty array: not queued, not retried, gone.
  //
  // The test still PASSED without this, which is why it needs saying. It passed
  // through the registration/reconcile fallback — at 1500ms the adapter arrives,
  // solana_stores.js _watchPreferredProvider reconciles, reads the already-
  // switched account and opens the card. Same assertion, different mechanism,
  // and the WS change-event path this test exists to cover stopped being
  // exercised. Measured at review 2026-08-26: 0 subscribers here at 1500ms,
  // 2 at the old 150ms.
  await expect
    .poll(() => page.evaluate(() => window.__phantomMockWsChangeSubscribers?.() ?? 0))
    .toBeGreaterThan(0);

  await page.evaluate(() =>
    window.phantom.solana.__switchAccount(2, { transientNull: true })
  );

  const dialog = page.getByRole("dialog");
  // The card names the handoff as a labelled from -> to pair now; the old
  // "It looks like you changed your wallet" subtitle restated the title.
  await expect(dialog).toContainText("Wallet changed");
  await expect(dialog).toContainText("Session");
  await expect(dialog).toContainText("Wallet");
  await expect(page).not.toHaveURL(/\/signin/);

  await page.keyboard.press("Escape");
  await expect(dialog).toBeVisible();
  await page.mouse.click(5, 5);
  await expect(dialog).toBeVisible();
  await expect(dialog.getByRole("button", { name: "Start New Session" })).toBeVisible();

  await dialog.getByRole("button", { name: "Start New Session" }).click();
  await expect.poll(async () => page.locator("body").getAttribute("data-user-id"))
    .not.toBe(originalUserId);
  await expect(page).not.toHaveURL(/\/signin/);
  // The HANDOFF card is gone — asserted on the modal stack rather than on "no
  // dialog at all", because the reload after a successful switch can legitimately
  // open a different card (the onboarding chain) for the wallet now signed in.
  await expect
    .poll(async () =>
      page.evaluate(() => {
        try {
          return Alpine.store("modals").isOpen("wallet-changed");
        } catch (e) {
          return false;
        }
      })
    )
    .toBe(false);
});

// BOTH INTERFACES, because for months this case certified exactly one of them.
//
// The recovery under test is solana_stores.js's focus handler: extension events
// are best-effort, so on refocus the watcher re-reads `provider.publicKey` and
// reconciles. This spec drove `setupPhantomMock(page)` — the LEGACY injected
// provider, whose publicKey is a field the mock rewrites — and passed. On the
// Wallet Standard adapter, which is what the watcher is actually bound to after
// the 'wallet-provider:registered' swap on a modern Phantom, the same re-read
// returned a CACHED account, so _handleAccountChanged was handed the address the
// user had just left, compared it to the session address, found them equal and
// returned early. The recovery re-affirmed the stale wallet and nothing opened.
//
// Measured on a live desk 2026-09-15 before the fix: adapter.publicKey 6ASf...
// while wallet.accounts[0] read 8pM1..., $store.wallet parked at 'live', and no
// card at all. Three of the four interface x arrival-path cells worked; this was
// the fourth. The fix is in wallet_provider.js's publicKey getter, unit-pinned
// by test/lib/wallet_standard_account_freshness_js_test.rb.
for (const walletStandard of [false, true]) {
  const iface = walletStandard ? "Wallet Standard" : "legacy injected";

  test(`refocusing recovers when Phantom misses its account-change event (${iface})`, async ({ page }) => {
    await setupPhantomMock(page, { walletStandard });
    await loginViaPhantom(page);

    // BIND TO THE INTERFACE UNDER TEST. The Wallet Standard adapter registers
    // 1500ms after load (phantom-mock models Phantom's real lifecycle), and
    // before it lands `walletProvider.get('phantom')` still answers with the
    // legacy fallback — so a switch sent too early would exercise the legacy
    // path under a Wallet Standard label.
    if (walletStandard) {
      await expect
        .poll(() => page.evaluate(() => window.__phantomMockWsChangeSubscribers?.() ?? 0))
        .toBeGreaterThan(0);
    }

    // THE TRANSITION'S STARTING POINT, ASSERTED. A wait that is already
    // satisfied by the state it waits for proves nothing; pinning 'live' first
    // is what makes the 'mismatched' below a transition rather than a reading.
    await expect
      .poll(() => page.evaluate(() => Alpine.store("wallet").state))
      .toBe("live");

    await page.evaluate(async () => {
      await window.phantom.solana.__switchAccount(3, { emitEvent: false });
      window.dispatchEvent(new Event("focus"));
    });

    // The store moves off 'live' — the fact the card is merely the presentation
    // of. Asserted separately so a regression in the watcher and a regression in
    // the modal host fail as different lines.
    await expect
      .poll(() => page.evaluate(() => Alpine.store("wallet").state))
      .toBe("mismatched");

    const dialog = page.getByRole("dialog");
    await expect(dialog).toContainText("Wallet changed");
    await expect(dialog.getByRole("button", { name: "Start New Session" })).toBeVisible();
    await expect(page).not.toHaveURL(/\/signin/);
  });
}

// THE PAGE ITSELF ANSWERS, not only the modal over it.
//
// The wallet-changed card is dismissible: false and covers this page, so for a
// reader it is the whole story right up until it closes — and it never opens at
// all for a switch the page deliberately suppressed (an operator cosign ceremony
// declares its addresses through expectSwitchesTo). Underneath it the account
// card was still presenting the session wallet's address and balances at full
// confidence. This asserts the card behind the modal has caught up.
test("the account card marks its balances when a different wallet is connected", async ({ page }) => {
  await setupPhantomMock(page, { walletStandard: true });
  await loginViaPhantom(page);
  await page.goto("/account");

  await expect
    .poll(() => page.evaluate(() => window.__phantomMockWsChangeSubscribers?.() ?? 0))
    .toBeGreaterThan(0);

  const notice = page.locator("[data-wallet-mismatch-notice]");
  const tiles = page.locator("[data-wallet-tiles]");

  // MOUNTED BEFORE IT IS NEEDED — the region has to be observable before the
  // text lands in it, or assistive tech never announces it. Present in the DOM,
  // hidden to the reader.
  await expect(notice).toHaveCount(1);
  await expect(notice).toBeHidden();
  await expect(tiles).not.toHaveClass(/opacity-50/);

  await page.evaluate(() => window.phantom.solana.__switchAccount(2));

  await expect(notice).toBeVisible();
  await expect(notice).toContainText("A different wallet is connected");
  await expect(tiles).toHaveClass(/opacity-50/);

  // It names the wallet that is actually connected — the fact the reader cannot
  // get anywhere else on this page.
  const live = await page.locator("[data-live-wallet-address]").textContent();
  const session = await page.locator("[data-session-wallet-address]").textContent();
  expect(live.trim()).not.toBe("");
  expect(live.trim()).not.toBe(session.trim());
});
