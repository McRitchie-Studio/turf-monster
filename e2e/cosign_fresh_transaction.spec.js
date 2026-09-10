const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// [e2e] The treasury cosign flow asks the SERVER for a fresh transaction at
// click time, and never carries a wire in the page.
//
// WHY A BROWSER IS THE ONLY WITNESS. The bug this pins was invisible to every
// server-side tier, because the server's response was never wrong. The page
// rendered a perfectly good transaction into `data-tx-serialized`; what broke
// it was TIME — the blockhash inside those bytes aged from page render, so by
// the first click it was usually dead, and clicking again re-sent the identical
// dead bytes. A String assertion sees a valid-looking attribute and passes. It
// took three months and $140 of unsent alpha-contest payouts before anyone
// established that retrying could never work.
//
// So this spec asserts things only a live browser produces:
//   · the module actually PARSED and installed its global (an import that
//     throws leaves the button inert with no server-side symptom at all),
//   · the live DOM carries no serialized wire, and
//   · invoking the flow issues a POST to .../rebuild BEFORE anything is
//     signed — which IS the fix. Fetching there is what starts the blockhash
//     window at the click instead of at page load.
//
// Phantom is stubbed: this spec is about what the page asks the server for
// before a wallet is ever involved, and the signing half needs a real
// extension. The server half is covered by
// test/controllers/admin/pending_transactions_controller_test.rb.
test.beforeEach(async ({ request }) => await reseed(request));

test.describe("Treasury cosign", () => {
  test("fetches a fresh transaction from the server when invoked @smoke", async ({ page }) => {
    // A stub provider, installed before any app script runs. cosignTransaction
    // bails out early without `window.solana.isPhantom`, so without this the
    // spec would assert nothing and still pass.
    await page.addInitScript(() => {
      window.solana = {
        isPhantom: true,
        publicKey: { toBase58: () => "CoSigner1111111111111111111111111111111111" },
        connect: async () => ({}),
        signTransaction: async (tx) => tx
      };
    });

    await loginAdmin(page);

    const rebuildRequests = [];
    await page.route("**/admin/pending_transactions/*/rebuild", async (route) => {
      rebuildRequests.push(route.request().url());
      // A deliberately unusable body: the flow must ask for a fresh wire, which
      // is what we are here to observe. What it does with the bytes afterwards
      // belongs to Phantom and to the server-side tests.
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ status: "rebuilt", serialized_tx: "" })
      });
    });

    await page.goto("/admin/pending_transactions");

    // 1. The module parsed and installed its global. No server-side tier can
    //    tell a loaded script from one that threw on import.
    const installed = await page.evaluate(() => typeof window.cosignTransaction);
    expect(installed).toBe("function");

    // 2. No wire in the live DOM. Asserted on the rendered document rather than
    //    the response body, so an attribute added later by script is caught too.
    const wires = await page.evaluate(
      () => document.querySelectorAll("[data-tx-serialized]").length
    );
    expect(wires).toBe(0);

    // 3. Invoking the flow asks the server to BUILD, before signing anything.
    await page.evaluate(() => window.cosignTransaction("ptx-probe", "Settle Contest"));
    await expect.poll(() => rebuildRequests.length, { timeout: 5000 }).toBe(1);
    expect(rebuildRequests[0]).toContain("/admin/pending_transactions/ptx-probe/rebuild");
  });
});
