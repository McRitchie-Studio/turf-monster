const { test, expect } = require("@playwright/test");
const { loginViaPhantom } = require("./helpers");
const { setupPhantomMock, MOCK_PUBKEY_B58 } = require("./phantom-mock");

// THE LEVEL-UP CELEBRATION AND THE CARD UNDERNEATH IT
// (task: level-up-reveals-stale-modal).
//
// Operator-reported on QA: a FREE entry succeeds — the join really happens, a
// refresh lands on the joined contest — but closing the "Level 6 / Free Entry
// Token" celebration REVEALS the on-chain "Sign Transaction — Approve your free
// entry in your wallet..." card still sitting underneath in its PROCESSING
// state. The player is shown a signing prompt for a transaction that already
// settled.
//
// WHY A BROWSER, and why these two tests rather than a markup assertion.
// Everything in play here is stack ARITHMETIC in inlined JS: how many entries
// $store.modals holds after the entry flow, which one $store.solanaModal.success()
// reaches, and which branch the layout's navbar-seeds-update handler takes. A
// source-text assertion can prove the strings shipped and cannot tell three
// stacked cards from one — see modal-lifecycle.md, "Testing a modal, honestly".
//
// THE PAIR IS THE POINT, and neither half is sufficient alone. The celebration
// handler deliberately branches: swap() over a DISMISSIBLE card, open() ON TOP
// of a non-dismissible one, so a signing prompt the user still has to act on is
// never clobbered. Test 1 asserts the settled card is gone; test 2 asserts the
// UNSETTLED one survives. A "fix" that makes the celebration always swap()
// passes the first and fails the second — which is the whole reason the second
// exists.
//
// Only the SERVER hops are stubbed (page.route). The wallet is the repo's mock
// provider, and the modal calls under test are made by the board's own
// confirmEntry(), never by this file.

const CONTEST_PATH = "/contests/world-cup-2026";

// The copy the screenshot showed, produced by the board at
// _turf_totals_board.html.erb when prepare_entry answers token_funded: true.
// Anchored as a regex against the dialog only: matching it anywhere on the page
// would let a stray occurrence elsewhere decide the verdict.
const SIGNING_COPY = /Approve your free entry in your wallet/i;

// eligibilityBlocker returns first_name_required (and then the age gate) ahead
// of every funding gate, so an entry never reaches the on-chain branch without
// both. Saved through the real endpoints, before the contest render.
async function nameTheUser(page) {
  const res = await page.request.post("/onboarding/first_name", {
    form: { first_name: "Testy" },
  });
  if (!res.ok()) throw new Error(`first_name failed: ${res.status()}`);
  const age = await page.request.post("/age/verify", {
    form: { date_of_birth: "1985-04-02" },
  });
  if (!age.ok()) throw new Error(`age/verify failed: ${age.status()}`);
}

// Drive the token count UP through the app's own hydrate path rather than
// assigning it — the same discipline free_entry_spend_mirror.spec.js documents.
// A web3 wallet with no USDC and no token is stopped by eligibilityBlocker
// before confirmEntry ever opens a modal.
async function hydrateTokens(page, tokens) {
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
  await page.waitForTimeout(1500);
  await page.evaluate(() => window.refreshSession().catch(() => null));
  await expect.poll(() => page.evaluate(() => Alpine.store("session").tokensAvailable)).toBe(tokens);
}

// The board's Alpine component — confirmEntry() lives here.
async function board(page) {
  await page.waitForFunction(() => !!document.querySelector(".hold-btn") && !!window.Alpine);
  return page.evaluateHandle(() =>
    Alpine.$data(document.querySelector(".hold-btn").closest("[x-data]"))
  );
}

// THE OBSERVABLE THIS SPEC IS BUILT ON. The host renders only current(), so the
// DOM shows one dialog however deep the stack is — the buried cards are exactly
// what the screen cannot tell you about. Entries on their way out are excluded:
// close() flips _closing at once and splices 220ms later, so counting them would
// make every assertion a race.
async function liveStack(page) {
  return page.evaluate(() =>
    Alpine.store("modals")
      .stack.filter((e) => !e._closing)
      .map((e) => e.id)
  );
}

// The board deserializes serialized_tx with solanaWeb3 and hands it to the
// provider, so the stub must be a REAL unsigned wire — a hand-waved null throws
// before the branch under test is reached. Built in-page from the same
// solanaWeb3 the app uses, with both signature slots empty.
async function buildUnsignedTx(page) {
  await page.evaluate((pk) => {
    window.__E2E_PHANTOM_PUBKEY__ = pk;
  }, MOCK_PUBKEY_B58);
  return page.evaluate(async () => {
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
    bytes.forEach((b) => {
      bin += String.fromCharCode(b);
    });
    return btoa(bin);
  });
}

// token_funded: true is the SERVER's own decision, echoed back by prepare_entry
// for exactly the copy this spec anchors on.
async function stubPrepare(page, serializedTx) {
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
}

// Arrive on the contest as a self-custody wallet holding one free entry, with
// the on-chain branch selected. contestOnchain is flipped by hand because
// e2e/seed.rb clears onchain_contest_id on every seeded contest (a real one
// needs a devnet create, which this lane may not perform). It selects WHICH
// BRANCH runs; it is not the thing under test.
async function arriveReadyToEnter(page) {
  await setupPhantomMock(page);
  await loginViaPhantom(page);
  await nameTheUser(page);
  await page.goto(CONTEST_PATH);
  await page.waitForFunction(() => typeof window.refreshSession === "function");
  await hydrateTokens(page, 1);
  const serializedTx = await buildUnsignedTx(page);
  await stubPrepare(page, serializedTx);
  const b = await board(page);
  await b.evaluate((c) => {
    c.contestOnchain = true;
  });
  return b;
}

test("a settled free entry leaves nothing under the level-up celebration", async ({ page }) => {
  const b = await arriveReadyToEnter(page);

  // Seeds that CROSS a level: 500 total from 60 earned puts the user at 440
  // before (level 5) and 500 after (level 6), so StateFanout's own arithmetic
  // decides leveledUp — this spec does not hand it the flag. The fanout then
  // dispatches navbar-seeds-update after its 2000ms delay, and the layout's
  // handler pops the celebration 900ms later. That real chain is the point:
  // the bug lives in how the celebration lands on the stack the entry left.
  await page.route("**/contests/*/confirm_onchain_entry", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        success: true,
        redirect: CONTEST_PATH,
        tx_signature: "SIG_SENTINEL_LEVELUP",
        token_consumed: true,
        seeds_earned: 60,
        seeds_total: 500,
        seeds_level: 6,
      }),
    })
  );

  await b.evaluate((c) => c.confirmEntry());
  await expect.poll(() => page.evaluate(() => Alpine.store("solanaModal").state)).toBe("success");

  // ONE card for one flow. The entry calls solanaModal.show() three times —
  // "Preparing Transaction", "Sign Transaction", "Confirming Onchain" — and
  // modals.open() PUSHES, so before the fix this read
  // ["onchain-tx", "onchain-tx", "onchain-tx"]. success() advances only
  // current(), which is why the two underneath stayed in processing forever.
  expect(
    await liveStack(page),
    "the entry flow left more than one onchain-tx card on the stack"
  ).toEqual(["onchain-tx"]);

  // The celebration arrives over a card that has already settled — dismissible
  // is true by now — so the handler SWAPS rather than stacking.
  await expect
    .poll(() => liveStack(page), { timeout: 15000 })
    .toEqual(["free-entry-earned"]);

  const dialog = page.getByRole("dialog");
  await expect(dialog.getByText("Level 6")).toBeVisible();

  await dialog.getByRole("button", { name: /^close$/i }).click();

  // THE REPORTED BUG, stated as the stack: closing the celebration must not pop
  // back to anything. Before the fix this was ["onchain-tx", "onchain-tx"] and
  // the screen showed the signing prompt for a transaction that had settled
  // three seconds earlier.
  await expect.poll(() => liveStack(page)).toEqual([]);
  await expect(page.getByRole("dialog")).toHaveCount(0);
});

test("a level-up mid-signature never clobbers the prompt still waiting on the user", async ({
  page,
}) => {
  const b = await arriveReadyToEnter(page);

  // The wallet never answers. This is the state the open()-on-top branch exists
  // to protect: the card says "Approve your free entry in your wallet...", it is
  // dismissible: false, and the transaction genuinely still needs this player.
  await page.evaluate(() => {
    const provider = window.walletProvider.detect();
    provider.signTransaction = function () {
      return new Promise(() => {});
    };
  });

  // Fire and forget — confirmEntry() never resolves while the wallet is silent.
  await b.evaluate((c) => {
    c.confirmEntry();
  });

  const dialog = page.getByRole("dialog");
  await expect(dialog.getByText(SIGNING_COPY)).toBeVisible();
  expect(await liveStack(page)).toEqual(["onchain-tx"]);
  expect(
    await page.evaluate(() => Alpine.store("modals").current().props.dismissible)
  ).toBe(false);

  // The level-up beat lands while the wallet is still silent. Dispatched
  // directly, and honestly so: the only producer of levelUp in the app is the
  // seeds fanout on a SUCCESSFUL entry, so this exact ordering is not a path a
  // user walks today — it is reachable when an entry awards seeds and then
  // throws before success(), and it is the INVARIANT the open()-on-top branch
  // exists to hold. The event is the one state_fanout.js builds; the handler
  // reading it is the layout's own, unstubbed.
  await page.evaluate(() =>
    window.dispatchEvent(
      new CustomEvent("navbar-seeds-update", {
        detail: { levelUp: true, oldLevel: 5, oldPct: 40, newLevel: 6, progress: 0 },
      })
    )
  );

  // ON TOP, not over. Two cards: the celebration is showing, the signing prompt
  // is preserved beneath it.
  await expect
    .poll(() => liveStack(page), { timeout: 10000 })
    .toEqual(["onchain-tx", "free-entry-earned"]);
  await expect(dialog.getByText("Level 6")).toBeVisible();

  await dialog.getByRole("button", { name: /^close$/i }).click();

  // And the player gets the prompt back, because the transaction still needs
  // the signature. Revealing this card is CORRECT here and a bug in the test
  // above; the difference is whether the transaction settled.
  await expect.poll(() => liveStack(page)).toEqual(["onchain-tx"]);
  await expect(page.getByRole("dialog").getByText(SIGNING_COPY)).toBeVisible();
  expect(await page.evaluate(() => Alpine.store("solanaModal").state)).toBe("processing");
});
