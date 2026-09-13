// THE RENAME'S RETURN LEG, asserted on the REAL route a wallet comes back to.
//
// Sibling of contest_entry_callback_registration.spec.js, and written the same
// way for the same reason: a spec that asserts "the intent is registered" on a
// page that happens to render the rename modal proves nothing about the page the
// wallet actually returns to. walletOps.resume() consumes the journal at take()
// BEFORE requireHandler runs, so an intent missing HERE loses the rename after
// the user has already approved it in their wallet — on-chain, unmirrored, with
// nothing left to retry.
//
// WHAT ONLY A BROWSER CAN SAY. The unit tests drive the handlers extracted from
// the partial; they cannot see whether the layout put them on this route, nor
// whether they survive being parsed as part of a real document. This file visits
// the callback and asserts nothing about any other page.
const { test, expect } = require("@playwright/test");

const CALLBACK = "/auth/phantom/callback";

test.describe("the page a wallet returns a rename to", () => {
  test("registers username_rename on the callback route itself @smoke", async ({ page }) => {
    // No query params: the callback's own script bails early without a pending
    // journal, which is fine — registration happens at page load, before any of
    // that, and is exactly what must be present when a REAL return arrives.
    await page.goto(CALLBACK);

    await expect
      .poll(() => page.evaluate(() => typeof window.SolanaStudio?.walletOps?.defined))
      .toBe("function");

    const registered = await page.evaluate(() =>
      window.SolanaStudio.walletOps.defined("username_rename")
    );

    expect(
      registered,
      "an unregistered intent here loses a rename that is already on-chain"
    ).toBe(true);
  });

  test("every global the return leg reaches for is present on that page @smoke", async ({ page }) => {
    // `defined()` only proves a NAME was registered. complete() then reaches for
    // four more things by name, and each one is a TypeError thrown after the
    // user approved — the single most expensive place to discover a missing
    // global. tmRenameFetch and tmRenamePollConfirmation exist precisely because
    // their importmap-module originals (authedFetch, pollConfirmation) are NOT
    // reliably here; asserting the wrappers is asserting the fix.
    await page.goto(CALLBACK);
    await expect
      .poll(() => page.evaluate(() => typeof window.tmCompleteUsernameRename))
      .toBe("function");

    const shapes = await page.evaluate(() => ({
      prepare: typeof window.tmPrepareUsernameRename,
      complete: typeof window.tmCompleteUsernameRename,
      fetch: typeof window.tmRenameFetch,
      poll: typeof window.tmRenamePollConfirmation,
      finalizeUrl: window.tmUsernameRenameFinalizeUrl,
    }));

    expect(shapes).toEqual({
      prepare: "function",
      complete: "function",
      fetch: "function",
      poll: "function",
      finalizeUrl: "/account/confirm_username",
    });
  });

  test("complete() finishes a wallet-broadcast rename on this page @smoke", async ({ page }) => {
    // THE RETURN LEG, END TO END, in a real browser on the real route — with the
    // wallet and the chain stubbed and nothing else. This is the beat that has no
    // desktop equivalent: on the inline transport studio-engine's leveling modal
    // posts confirm_username itself, and here that modal does not exist, so if
    // complete() does not post it nobody does.
    await page.goto(CALLBACK);
    await expect
      .poll(() => page.evaluate(() => typeof window.tmCompleteUsernameRename))
      .toBe("function");

    const outcome = await page.evaluate(async () => {
      const posted = [];
      // THE CSRF TAG IS INSTALLED BY THIS TEST, and that is the point rather than
      // a shortcut. The e2e server disables forgery protection, so
      // csrf_meta_tags emits NOTHING on any page here — measured: absent on "/"
      // too, not just on this route. Asserting the token was non-empty as it
      // shipped would therefore have measured the environment and failed on
      // correct code, which is exactly what the first cut of this file did.
      // Installing the tag makes the LIVE-READ path observable in a browser
      // regardless of how that server is configured.
      const meta = document.createElement("meta");
      meta.name = "csrf-token";
      meta.content = "LIVE_CSRF";
      document.head.appendChild(meta);

      // The chain said yes. Confirmation itself is solana's business, not this
      // flow's, and polling a real RPC from a test is not a property worth
      // asserting here.
      window.pollConfirmation = () => Promise.resolve({ confirmationStatus: "confirmed" });
      window.authedFetch = undefined;
      const realFetch = window.fetch.bind(window);
      window.fetch = (url, opts) => {
        if (String(url).includes("confirm_username")) {
          posted.push({ url: String(url), body: JSON.parse(opts.body), csrf: opts.headers["X-CSRF-Token"] });
          return Promise.resolve({ status: 200, json: () => Promise.resolve({ status: "saved", username: "zed" }) });
        }
        return realFetch(url, opts);
      };

      const ctx = {
        token: "TOK",
        finalizeUrl: window.tmUsernameRenameFinalizeUrl,
        csrfToken: "JOURNALLED_CSRF",
      };
      const result = { sendStrategy: "wallet-broadcasts", signature: "WALLET_SIG", signedTransaction: null };

      const value = await window.tmCompleteUsernameRename(ctx, result, { transaction: "unused" });

      // SECOND PASS, WITH THE TAG GONE — a document served without
      // csrf_meta_tags, which is what sent the first cut of this file red.
      meta.remove();
      await window.tmCompleteUsernameRename(ctx, result, { transaction: "unused" });

      return { value, posted };
    });

    expect(outcome.posted, "the callback document must post the finalize itself").toHaveLength(2);
    expect(outcome.posted[0].url).toContain("/account/confirm_username");
    expect(outcome.posted[0].body).toEqual({ token: "TOK", proof: "WALLET_SIG" });
    // This document's OWN tag wins while it has one — it cannot be stale.
    expect(outcome.posted[0].csrf).toBe("LIVE_CSRF");
    // And with no tag at all the caller's journalled token carries it, rather
    // than an empty header 422-ing a rename that is already on-chain.
    expect(outcome.posted[1].csrf, "the ctx fallback must cover a document with no csrf tag").toBe(
      "JOURNALLED_CSRF"
    );
    // studio-engine's callback navigates to result.value.redirect, falling back
    // to '/'. Without this the user lands on the site root after a rename.
    expect(outcome.value.redirect).toBe("/account");
    expect(outcome.value.proof).toBe("WALLET_SIG");
  });

  test("the callback page does NOT render the account page @smoke", async ({ page }) => {
    // THE CONTROL. Without it, everything above would still pass if someone
    // "fixed" a missing registration by rendering account chrome onto the
    // callback route — which would work, and would drag a signed-in page onto a
    // route that must serve a signed-out wallet return. If this goes red, the
    // registration moved back somewhere page-specific.
    await page.goto(CALLBACK);

    const hasRenameModal = await page.evaluate(
      () => !!document.querySelector('[x-data^="levelingActionModal"]')
    );
    expect(hasRenameModal, "the intent must be registered independently of the rename UI").toBe(false);
  });
});
