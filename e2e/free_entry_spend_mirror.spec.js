const { test, expect } = require("@playwright/test");
const { loginViaPhantom } = require("./helpers");
const { setupPhantomMock, MOCK_PUBKEY_B58 } = require("./phantom-mock");

// THE LABEL AFTER THE TOKEN IS SPENT (task: hold-for-free-entry, PR #386 blocker 2).
//
// free_entry_web3.spec.js already asserts the CTA follows the count. It cannot
// catch this bug, and the reason is the whole point of this file: it SETS the
// count by hand (`Alpine.store("session").tokensAvailable = n`). Hand-setting
// asserts the BINDING. The bug was that nothing in production ever produced the
// 0 — every write to tokensAvailable in the app was an acquisition (the mint
// poll, _paypal_sdk, the session hydrate), refreshBalance touches only
// usdc/usdtCents, and the board's header comment claimed a refreshSession()
// that this board never calls. So a wallet that entered free kept reading
// "Hold for Free Entry", eligibilityBlocker waved the stale count through, and
// the server correctly built a USDC transfer: charged after holding a button
// that said Free Entry.
//
// So neither test below ever assigns tokensAvailable.
//   ARRANGE through the app's real acquisition writer — refreshSession()
//           (solana_utils.js) hydrating from /account/session_refresh.
//   ACT     through the real production method that owns both success
//           branches — the board component's confirmEntry().
//   ASSERT  on the 0 the code computed, and on the copy a user would read.
//
// Only the SERVER responses are stubbed (page.route), because the irreversible
// on-chain consume is not something a PR lane may perform. `token_consumed` is
// the server's own flag on both endpoints — ContestsController#enter and
// #confirm_onchain_entry.

// The on-chain-capable seeded contest (the same one onchain.spec.js drives).
const CONTEST_PATH = "/contests/world-cup-2026";

// Drive the count UP through the app's own hydrate path. Never an assignment.
async function hydrateTokens(page, tokens) {
  // Let the layout's own hydrateNavbar hydrate finish first. refreshSession()
  // is lock-deduped (lockedFetch('session')) and aborts/serialises against an
  // in-flight twin, so calling into a live one hands back a rejected fetch.
  await page.waitForTimeout(1500);

  await page.route("**/account/session_refresh", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ usdc: "0.0", usdt: "0.0", tokens: String(tokens) }),
    })
  );

  await expect
    .poll(
      async () => {
        await page.evaluate(() => window.refreshSession().catch(() => null));
        return page.evaluate(() => Alpine.store("session").tokensAvailable);
      },
      { timeout: 20000, intervals: [1000, 1000, 1000, 1500, 1500, 2000, 2000, 2000] }
    )
    .toBe(tokens);

  // A hydrate that was already in flight when the route was installed resolves
  // from the REAL (unstubbed) response and lands AFTER the poll is satisfied,
  // stamping the store back to 0. Settle, then re-drive, so the arrange holds.
  await page.waitForTimeout(1500);
  await page.evaluate(() => window.refreshSession().catch(() => null));
  await expect.poll(() => page.evaluate(() => Alpine.store("session").tokensAvailable)).toBe(tokens);
}

async function idleLabels(page) {
  return page.$$eval(".hold-btn .hold-text li:nth-child(1)", (els) =>
    els.map((e) => e.textContent.trim())
  );
}

// Alpine re-renders the x-text binding on its own tick, so poll the painted
// copy rather than reading it the instant the store changes.
async function expectLabels(page, copy) {
  await expect
    .poll(async () => {
      const seen = await idleLabels(page);
      return seen.length ? Array.from(new Set(seen)).sort() : null;
    })
    .toEqual([copy]);
}

// The board's Alpine component — confirmEntry() lives here.
async function board(page) {
  await page.waitForFunction(
    () => !!document.querySelector(".hold-btn") && !!window.Alpine
  );
  return page.evaluateHandle(() =>
    Alpine.$data(document.querySelector(".hold-btn").closest("[x-data]"))
  );
}

// eligibilityBlocker returns first_name_required AHEAD of every funding gate,
// so an entry never reaches either success branch without one. Saved through
// the real endpoint the onboarding card posts to, BEFORE the contest render, so
// the server emits firstNameRequired:false into #session-context.
async function nameTheUser(page) {
  const res = await page.request.post("/onboarding/first_name", {
    form: { first_name: "Testy" },
  });
  if (!res.ok()) throw new Error(`first_name failed: ${res.status()}`);

  // Same story one gate down: the age gate (ENABLE_AGE_GATE) is checked ahead of
  // tokens/balance. Attested through its only writer, AgeVerificationsController.
  const age = await page.request.post("/age/verify", {
    form: { date_of_birth: "1985-04-02" },
  });
  if (!age.ok()) throw new Error(`age/verify failed: ${age.status()}`);
}

async function tokensNow(page) {
  return page.evaluate(() => Alpine.store("session").tokensAvailable);
}

// Both tests sign in with the mock Phantom wallet, which is the trigger's own
// wallet: a self-custody account holding one entry token and no USDC. It also
// keeps eligibilityBlocker's wallet_setup_required gate out of the way — that
// gate fires for a MANAGED wallet under the USDC threshold, and clearing it
// would mean faking a sign-in-time policy verdict. Which of the two success
// branches runs is decided by `useOnchainFlow = sess.isWeb3 && contestOnchain`,
// so the contest flag selects the branch, not the wallet.

test("the /enter success branch spends the token, and the CTA stops promising a free one", async ({
  page,
}) => {
  await setupPhantomMock(page);
  await loginViaPhantom(page);
  await nameTheUser(page);
  await page.goto(CONTEST_PATH);
  await page.waitForFunction(() => typeof window.refreshSession === "function");

  await hydrateTokens(page, 1);
  await expectLabels(page, "Hold for Free Entry");

  // contestOnchain is false on every seeded contest (e2e/seed.rb clears
  // onchain_contest_id), so confirmEntry takes the `else` branch: POST
  // /contests/:id/enter — the branch the managed-wallet path always takes, and
  // the one that never mirrored a spend at all. A tx_signature comes back,
  // which keeps us on the success modal instead of navigating away.
  await page.route("**/contests/*/enter", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        success: true,
        redirect: CONTEST_PATH,
        tx_signature: "SIG_SENTINEL_MANAGED",
        token_consumed: true,
        seeds_earned: 0,
        seeds_total: 0,
        seeds_level: 1,
      }),
    })
  );

  const b = await board(page);
  await b.evaluate((c) => c.confirmEntry());

  // The 0 the CODE produced. Before the fix this branch never wrote to the
  // store at all — it punched the navbar badge and left this at 1.
  await expect.poll(() => tokensNow(page)).toBe(0);
  await expectLabels(page, "Hold to Confirm");

  // And the consequence the user actually felt: the next hold is no longer
  // waved through as free.
  const verdict = await page.evaluate(() =>
    window.eligibilityBlocker(Alpine.store("session"), 1900)
  );
  expect(verdict).not.toBeNull();
});

test("the phantom-direct success branch spends the token, and the CTA stops promising a free one", async ({
  page,
}) => {
  await setupPhantomMock(page);
  await loginViaPhantom(page);
  await nameTheUser(page);
  await page.goto(CONTEST_PATH);
  await page.waitForFunction(() => typeof window.refreshSession === "function");
  await page.evaluate((pk) => { window.__E2E_PHANTOM_PUBKEY__ = pk; }, MOCK_PUBKEY_B58);

  await hydrateTokens(page, 1);
  await expectLabels(page, "Hold for Free Entry");

  // The phantom-direct branch: prepare -> wallet signs -> confirm. Only the two
  // server hops are stubbed; the mock provider does the signing.
  // The board deserializes serialized_tx with solanaWeb3 and hands it to the
  // provider, so the stub must be a REAL unsigned wire — a hand-waved null
  // would throw before the branch under test. Built in-page from the same
  // solanaWeb3 the app uses, with both signature slots empty.
  const serializedTx = await page.evaluate(async () => {
    const kp = solanaWeb3.Keypair.generate();
    const tx = new solanaWeb3.Transaction();
    tx.add(
      solanaWeb3.SystemProgram.transfer({
        fromPubkey: new solanaWeb3.PublicKey(window.__E2E_PHANTOM_PUBKEY__),
        toPubkey: kp.publicKey,
        lamports: 1,
      })
    );
    tx.feePayer = new solanaWeb3.PublicKey(window.__E2E_PHANTOM_PUBKEY__);
    tx.recentBlockhash = solanaWeb3.Keypair.generate().publicKey.toBase58();
    const bytes = tx.serialize({ requireAllSignatures: false, verifySignatures: false });
    let bin = "";
    bytes.forEach((b) => { bin += String.fromCharCode(b); });
    return btoa(bin);
  });

  await page.route("**/contests/*/prepare_entry", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        success: true,
        entry_id: 1,
        entry_pda: "PDA_SENTINEL",
        ptx_slug: "PTX_SENTINEL",
        token_funded: true,
        serialized_tx: serializedTx,
      }),
    })
  );
  await page.route("**/contests/*/confirm_onchain_entry", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        success: true,
        redirect: CONTEST_PATH,
        tx_signature: "SIG_SENTINEL_PHANTOM",
        token_consumed: true,
        seeds_earned: 0,
        seeds_total: 0,
        seeds_level: 1,
      }),
    })
  );

  const b = await board(page);
  // useOnchainFlow = sess.isWeb3 && contestOnchain. e2e/seed.rb clears
  // onchain_contest_id on every seeded contest (a real one needs a devnet
  // create — a QA write act this lane may not perform), so the flag is flipped
  // here. It selects WHICH BRANCH runs; it is not the thing under test, and the
  // 0 asserted below is still computed by the branch, never assigned.
  await b.evaluate((c) => { c.contestOnchain = true; });
  // The signing leg needs a real wire; when the mock cannot produce one the
  // method throws and the store is untouched — which would read as a PASS of
  // the wrong thing. So assert we actually REACHED the success branch.
  await b.evaluate((c) => c.confirmEntry().catch(() => {}));
  await expect
    .poll(() => page.evaluate(() => Alpine.store("solanaModal").txSignature || null))
    .toBe("SIG_SENTINEL_PHANTOM");

  await expect.poll(() => tokensNow(page)).toBe(0);
  await expectLabels(page, "Hold to Confirm");
});
