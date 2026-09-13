const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// [e2e] The admin wallet flows declare themselves DESKTOP-ONLY, in a browser.
//
// WHY A BROWSER IS THE ONLY WITNESS. Every claim below is a thing no server-side
// tier can see. test/lib/wallet_desktop_only_js_test.rb owns the copy rules and
// test/integration/wallet_stub_parity_test.rb proves the inlined stub agrees
// with the module — but neither can answer whether the gate ARRIVES: whether the
// notice actually PAINTS on a phone, whether the buttons are actually DISABLED,
// or whether the click-time refusal actually stops the network call. An ERB
// comment that terminates early, a partial that stops being rendered, a script
// swallowed by a phantom element — each leaves every other tier green and the
// page wide open on a phone.
//
// THE TWO DIRECTIONS, and the second is the one that keeps this honest:
//   · a phone is refused, before it taps and again if it taps anyway, and
//   · a DESKTOP is untouched — notice hidden, buttons live, and the flow still
//     reaches the server. A gate that refused everyone would satisfy every
//     assertion in the first group.
//
// THE DESKTOP STUB INJECTS `window.solana` AND NOT `window.phantom.solana`, on
// purpose. That is a legacy Phantom build: a desktop that CAN sign, and one that
// a gate composing requireProvider() would refuse (detect() reads
// window.phantom.solana). Keeping the stub in that shape is what pins
// requireDesktop to asking about the DEVICE only.
const IPHONE =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";

const NOTICE = "#wallet-desktop-only-notice";
const COSIGN_BUTTON = "button[data-desktop-only-action]";

// A working Phantom, installed before any app script runs, so the ONLY thing
// that can stop the flow below is the device gate.
async function stubLegacyPhantom(page) {
  await page.addInitScript(() => {
    const key = { toBase58: () => "CoSigner1111111111111111111111111111111111" };
    window.solana = {
      isPhantom: true,
      publicKey: key,
      // RESOLVES A REAL publicKey, and that detail is load-bearing. With
      // `connect` resolving {}, an UNGATED lock flow died on
      // `resp.publicKey.toBase58()` before it ever fetched — so "the server was
      // never called" stayed true with the gate deleted, and the mutation that
      // removed it survived. A stub that lets the flow run is what makes the
      // absence of a request evidence of the gate rather than of the stub.
      connect: async () => ({ publicKey: key }),
      signTransaction: async (tx) => tx
    };
  });
}

// The treasury page renders its Co-sign buttons only for PENDING rows, and the
// e2e seed deletes every PendingTransaction. Create two so the loop is really a
// loop — a marker applied outside it would gate one and leave the rest live.
async function seedPendingSignatures(request, live) {
  const response = await request.post("/test/set_pending_signatures", { form: { live, stale: 0 } });
  expect(response.ok()).toBe(true);
}

// The sentence the MODAL is showing, read from the store rather than from page
// text. This page also PAINTS that sentence into the desktop-only notice, so a
// getByText() assertion is satisfied by the notice whether or not the flow
// refused anything — which is exactly how the first cut of this spec let a
// mutation that deleted lock_contest.js's gate pass.
async function modalError(page) {
  return page.evaluate(() => {
    const m = window.Alpine && window.Alpine.store("solanaModal");
    return m ? { state: m.state, title: m.title, errorMessage: m.errorMessage } : null;
  });
}

// Count the rebuild POST — the first thing the cosign flow does once it is past
// its guards, and therefore the observable that says whether the gate held.
async function watchRebuilds(page) {
  const seen = [];
  await page.route("**/admin/pending_transactions/*/rebuild", async (route) => {
    seen.push(route.request().url());
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ status: "rebuilt", serialized_tx: "" })
    });
  });
  return seen;
}

test.beforeEach(async ({ request }) => {
  await reseed(request);
  await seedPendingSignatures(request, 2);
});

// PUT THE TREASURY BACK EMPTY. `reseed` does NOT delete PendingTransactions —
// it clears caches, non-core users, entries and geo — and the lane runs one
// server with one worker, so rows seeded here survive every later spec in the
// shard. e2e/audit.spec.js:126 asserts the treasury's EMPTY state, and this
// file sorts before it, so without this cleanup that spec fails on CI (three
// attempts, no flake) while every spec in this file passes. Measured, not
// predicted: reproduced locally with
// `npx playwright test e2e/admin_desktop_only.spec.js e2e/audit.spec.js`.
test.afterEach(async ({ request }) => await seedPendingSignatures(request, 0));

test.describe("admin treasury on a phone", () => {
  test.use({ userAgent: IPHONE });

  test("declares desktop-only before the operator taps anything @smoke", async ({ page }) => {
    await stubLegacyPhantom(page);
    const rebuilds = await watchRebuilds(page);
    await loginAdmin(page);
    await page.goto("/admin/pending_transactions");

    // 1. THE PAINT. Hidden in the response body; revealed only by the gate, so
    //    seeing it here proves the script ran and took the mobile branch.
    const notice = page.locator(NOTICE);
    await expect(notice).toBeVisible();

    // 2. THE SENTENCE, read from the live DOM. It is not in the server
    //    response — the slot is empty there — so this text can only have come
    //    from walletProvider.desktopOnlyMessage().
    await expect(notice.locator("[data-desktop-only-message]"))
      .toHaveText(/a phone cannot reach a signer wallet/i);

    // 3. EVERY Co-sign button is disabled. Both rows, not just the first.
    const buttons = page.locator(COSIGN_BUTTON);
    await expect(buttons).toHaveCount(2);
    for (let i = 0; i < 2; i++) {
      await expect(buttons.nth(i)).toBeDisabled();
    }

    // 4. AND THE BACKSTOP HOLDS. Invoked directly — the way a re-enabled
    //    button or a stale onclick would reach it — the flow refuses without
    //    asking the server for anything. This is the assertion that fails if
    //    the gate is removed from cosign.js while the notice stays.
    await page.evaluate(() => window.cosignTransaction("ptx-probe", "Settle Contest"));

    await expect.poll(() => modalError(page).then((m) => m && m.state)).toBe("error");
    const refusal = await modalError(page);
    expect(refusal.title).toBe("Desktop Required");
    expect(refusal.errorMessage).toMatch(/a phone cannot reach a signer wallet/i);
    expect(rebuilds).toHaveLength(0);
  });

  // The contest lock/conclude flow, which is the ONE of the four with no notice
  // to paint: its buttons live in app/views/contests/** (the contest header, the
  // show page, the turf-totals leaderboard), so no single view owns it. Its
  // whole declaration is the click-time refusal, which makes this the only tier
  // that can see the flow is gated at all.
  test("the contest lock flow refuses without asking the server", async ({ page }) => {
    await stubLegacyPhantom(page);

    const prepares = [];
    await page.route("**/contests/*/prepare_lock_time", async (route) => {
      prepares.push(route.request().url());
      await route.fulfill({ status: 200, contentType: "application/json", body: "{}" });
    });

    await loginAdmin(page);
    await page.goto("/admin/pending_transactions");

    // Invoked directly, the way its onclick does. `window.solana` is a working
    // Phantom here, so the pre-existing isPhantom check cannot be what stops it.
    await page.evaluate(() => window.lockContestViaPhantom("probe-contest", 0));

    await expect.poll(() => modalError(page).then((m) => m && m.state)).toBe("error");
    const refusal = await modalError(page);
    expect(refusal.title).toBe("Desktop Required");
    expect(refusal.errorMessage).toMatch(/a phone cannot reach a signer wallet/i);
    expect(prepares).toHaveLength(0);
  });

  test("the refusal never surfaces a null dereference", async ({ page }) => {
    // No wallet stub at all: this is a bare iOS Safari, which is the browser
    // that printed "null is not an object (evaluating 'provider.connect')" into
    // a transaction modal in production on 2026-09-07.
    await loginAdmin(page);
    await page.goto("/admin/pending_transactions");

    const refusal = await page.evaluate(async () => {
      try {
        window.walletProvider.requireDesktop();
        return { threw: false };
      } catch (e) {
        return { threw: true, message: e.message, isMobile: window.walletProvider.isMobile() };
      }
    });

    expect(refusal.isMobile).toBe(true);
    expect(refusal.threw).toBe(true);
    expect(refusal.message).not.toMatch(/is not an object/i);
    expect(refusal.message).not.toMatch(/\bnull\b/i);
    expect(refusal.message).not.toMatch(/not a function/i);
    expect(refusal.message).toMatch(/desktop/i);
  });
});

test.describe("admin treasury on a desktop", () => {
  test("is left alone — no notice, live buttons, and the flow still runs", async ({ page }) => {
    await stubLegacyPhantom(page);
    const rebuilds = await watchRebuilds(page);
    await loginAdmin(page);
    await page.goto("/admin/pending_transactions");

    // The notice stays hidden. Asserted on the LIVE element rather than the
    // response body: a gate that mis-read the UA would reveal it here.
    await expect(page.locator(NOTICE)).toBeHidden();

    const buttons = page.locator(COSIGN_BUTTON);
    await expect(buttons).toHaveCount(2);
    await expect(buttons.first()).toBeEnabled();

    // And the supported path is genuinely unchanged: the flow reaches the
    // server exactly as e2e/cosign_fresh_transaction.spec.js observes it. The
    // stub is a legacy Phantom (window.solana only), so this also fails if the
    // gate ever starts asking the wallet question detect() answers.
    await page.evaluate(() => window.cosignTransaction("ptx-probe", "Settle Contest"));
    await expect.poll(() => rebuilds.length, { timeout: 5000 }).toBe(1);
  });
});
