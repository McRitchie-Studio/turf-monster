const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// [e2e] THE WALLET SIGNAL ON A COSIGN CEREMONY PAGE, in a real browser.
//
// The companions are test/lib/wallet_signal_js_test.rb (the state machine, run
// under node against the real solana-studio identity source) and
// test/views/wallet_signal_component_test.rb (the markup). Neither can see the
// SCREEN: a component whose x-data was truncated by a stray quote renders
// byte-identical markup and every Ruby assertion stays green over a card that
// does nothing. Only a browser can tell those apart.
//
// WHY THIS PAGE. /admin/pending_transactions deliberately suppresses the
// non-dismissible wallet-changed card, because a treasury cosign walks the
// operator through the vault's signers on purpose and a card over a
// half-collected transaction strands it. The suppression is correct and stays.
// What it left behind was a page that could not say which account Phantom was
// on — mid-ceremony or after an accidental switch. This is the spec for what
// went in its place.
//
// THE ASSERTION THAT MATTERS MOST is the fourth one: a switch to an undeclared
// wallet WHILE a ceremony is running still reads as a warning. The engine offers
// StudioSession.expectChange to mark a switch expected, but its holds are per
// SOURCE, not per ADDRESS — one taken here would mark a switch to ANY wallet
// expected, silently, for as long as it was held. This app takes no such hold
// and scopes by address instead, and that is the property under test.

const SESSION_WALLET = "foUuRyeibadQoGdKXZ9pBGDqmkb1jY1jYsu8dZ29nds";
const DECLARED_WALLET = "DecLared1111111111111111111111111111111111";
const STRANGER_WALLET = "Stranger111111111111111111111111111111111";

test.beforeEach(async ({ request }) => await reseed(request));

test.describe("Wallet signal on a cosign ceremony page", () => {
  test("the indicator follows an undeclared switch, declared or not @smoke", async ({ page }) => {
    // A stub provider installed before any app script runs, so the identity
    // source binds to it the way it binds to a real extension. It reports
    // through accountChanged, which is Phantom's own event.
    await page.addInitScript(() => {
      const handlers = {};
      const provider = {
        isPhantom: true,
        name: "phantom",
        publicKey: null,
        on: (event, cb) => { (handlers[event] = handlers[event] || []).push(cb); },
        removeListener: (event, cb) => {
          handlers[event] = (handlers[event] || []).filter((fn) => fn !== cb);
        },
        connect: async () => ({ publicKey: provider.publicKey }),
        disconnect: async () => {},
        signTransaction: async (tx) => tx
      };
      // The test's hand on the wallet. Sets the address the provider reports
      // LIVE, then fires the event — never a cached copy, because an adapter
      // that answered from a cached value is the defect this app already paid
      // for once.
      window.__setWallet = (address) => {
        provider.publicKey = address ? { toBase58: () => address } : null;
        (handlers.accountChanged || []).forEach((cb) => cb(provider.publicKey));
      };
      window.solana = provider;
      window.phantom = { solana: provider };
    });

    await loginAdmin(page);
    await page.goto("/admin/pending_transactions");

    // The page-level signal exists at all. Before this change all three cosign
    // surfaces carried none.
    const panel = page.locator("[data-wallet-signal-variant=panel]");
    await expect(panel).toHaveCount(1);

    // The signal must resolve without a wallet connected — the pre-auth /
    // no-connection state is a first-class value, not an absence.
    await page.waitForFunction(() => window.Alpine && window.Alpine.store("walletSignal"));
    await expect(panel).not.toHaveAttribute("data-wallet-signal-state", "");

    // This admin signed in by email, so the session binds no wallet and a
    // browser wallet can never mismatch it. Make it a wallet session the way
    // the server describes one, then drive the wallet.
    await page.evaluate((address) => {
      document.body.dataset.walletAddress = address;
      const el = document.getElementById("session-context");
      const payload = JSON.parse(el.textContent);
      payload.mode = "web3";
      el.textContent = JSON.stringify(payload);
    }, SESSION_WALLET);

    const settle = async (address) => {
      await page.evaluate((a) => window.__setWallet(a), address);
      await page.waitForTimeout(150);
    };

    // 1. The browser is holding the wallet this session signed in with.
    await settle(SESSION_WALLET);
    await expect(panel).toHaveAttribute("data-wallet-signal-state", "live");

    // 2. AN UNDECLARED SWITCH. Nobody asked for this wallet.
    await settle(STRANGER_WALLET);
    await expect(panel).toHaveAttribute("data-wallet-signal-state", "changed");
    await expect(page.locator("[data-wallet-signal-changed-note]")).toBeVisible();

    // The navbar chip is the app-wide half of the same fact, and it is on every
    // page rather than only on the three that run ceremonies.
    const chip = page.locator("[data-wallet-signal-variant=chip]").first();
    await expect(chip).toHaveAttribute("data-wallet-signal-state", "changed");

    // 3. A DECLARED switch — what a ceremony does on purpose. This is the same
    //    call cosign.js makes before it starts collecting signatures.
    await page.evaluate((address) => {
      window.Alpine.store("wallet").expectSwitchesTo([address]);
    }, DECLARED_WALLET);
    await settle(DECLARED_WALLET);
    await expect(panel).toHaveAttribute("data-wallet-signal-state", "expected");
    await expect(page.locator("[data-wallet-signal-expected-note]")).toBeVisible();
    await expect(page.locator("[data-wallet-signal-changed-note]")).toBeHidden();

    // 4. THE ONE A SOURCE-SCOPED HOLD WOULD HAVE SILENCED. The ceremony is still
    //    running, and its declared list still holds DECLARED_WALLET — but this
    //    wallet is not on it.
    await settle(STRANGER_WALLET);
    await expect(panel).toHaveAttribute("data-wallet-signal-state", "changed");
    await expect(page.locator("[data-wallet-signal-changed-note]")).toBeVisible();

    // 5. THE CEREMONY ENDS, AND THE OPERATOR HAS NOT TOUCHED PHANTOM. cosign.js
    //    clears the declared list in its `finally` the instant the last signature
    //    is collected, while the wallet is still parked on the signer it just
    //    used. Every successful ceremony shipped a red panel here, saying no
    //    ceremony had asked for this wallet seconds after one had. No __setWallet
    //    call: the false alarm arrived without one, so this must too.
    await settle(DECLARED_WALLET);
    await expect(panel).toHaveAttribute("data-wallet-signal-state", "expected");
    await page.evaluate(() => window.Alpine.store("wallet").clearExpectedSwitches());
    await page.waitForTimeout(150);
    await expect(panel).toHaveAttribute("data-wallet-signal-state", "expected");
    await expect(page.locator("[data-wallet-signal-ended-note]")).toBeVisible();
    await expect(page.locator("[data-wallet-signal-changed-note]")).toBeHidden();
    await expect(page.locator("[data-wallet-signal-expected-note]")).toBeHidden();
    // Calm on the SCREEN, not merely in the state attribute: the alarm's
    // affordance is the red border, and this is where it must not be.
    await expect(panel).not.toHaveClass(/border-red-500/);

    // 6. A disconnect is not a switch to someone else. It degrades to read-only
    //    and says so, rather than accusing anyone.
    await settle(null);
    await expect(panel).toHaveAttribute("data-wallet-signal-state", "disconnected");

    // 7. Back to the session wallet, and the page is calm again.
    await settle(SESSION_WALLET);
    await expect(panel).toHaveAttribute("data-wallet-signal-state", "live");
  });
});
