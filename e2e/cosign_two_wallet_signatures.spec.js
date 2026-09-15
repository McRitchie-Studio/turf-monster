const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// [e2e] The treasury cosign flow collects TWO Phantom signatures onto ONE
// transaction, and reports both wallets to the server.
//
// WHY A BROWSER IS THE ONLY WITNESS. turf-vault v0.26 raised six operator
// actions to THREE vault signatures. The server contributes one (the admin
// key, patched into its slot at build time), so the browser now owes two. Every
// step of that owing lives in web3.js and in Phantom's one-account-at-a-time
// model, and no server-side tier can reach any of it:
//
//   · PHANTOM EXPOSES ONE ACCOUNT. Switching is a human act inside the
//     extension, so collection is sequential: ask, WAIT, sign, ask again. A
//     String assertion cannot tell a flow that waits from one that signs twice
//     with whatever account happens to be selected — and the second reading
//     produces a transaction with one slot filled twice and DuplicateSigner
//     from the chain.
//   · A SIGNATURE IS NOT PRESERVED BY BEING HANDED BACK. cosign_signatures.js
//     decodes a FRESH transaction per wallet, extracts only that wallet's 64
//     bytes, and merges with addSignature precisely because Phantom's return
//     shape is not pinned. Whether the merge actually produces one wire that
//     verifies is an ed25519 question, answered here by web3.js itself.
//   · AN EMPTY SLOT IS ZERO-FILLED, NOT ABSENT. "present in the signatures
//     array" and "signed" are different facts, and reading the first as the
//     second is how a transaction reaches the chain one signature short and
//     comes back 6046 InsufficientSigners naming nobody.
//
// SO THIS SPEC IS BUILT TO FAIL AGAINST THE OLD SINGLE-SIGNATURE CODE, which
// is the whole point of writing it. Against that code signTransaction is
// called ONCE, neither request body carries extra_cosigners, and the wire it
// tried to serialize was one signature short of complete — so serialize()
// throws and nothing reaches /broadcast at all.
//
// THE STUB IS A REAL WALLET, NOT A SHRUG. window.solana holds two REAL
// solanaWeb3 keypairs and signs with partialSign, so the signatures this spec
// asserts on are genuine ed25519 signatures over the real message bytes. That
// matters: cosign_signatures.js finishes with merged.serialize(), which
// VERIFIES every signature and refuses to emit a wire that does not check out.
// A stub returning 64 random bytes would fail there for a reason that has
// nothing to do with the behaviour under test.
//
// The server halves are covered by
// test/controllers/admin/pending_transactions_controller_test.rb and
// test/services/solana/cosign_plan_test.rb; the module's own unit rules by
// test/services/solana/governance_thresholds_test.rb.
//
// ── ONE FIXTURE IS THE SPEC'S, AND IT IS DECLARED HERE ────────────────────
//
// In the second test the <select data-extra-cosigner> is BUILT BY THIS SPEC,
// because it cannot be rendered in this lane — for TWO independent reasons,
// either of which alone would be enough:
//
//   1. GOVERNANCE IS OFF HERE. The view's gate is `tx.extra_cosigners_needed`,
//      which routes through Solana::CosignPlan#extra_cosigners_needed and
//      returns 0 unless Solana::Config.governance?. Nothing in the e2e lane
//      sets SOLANA_VAULT_GOVERNANCE (playwright.config.js's webServer.env and
//      bin/e2e-parallel both leave it unset), and unset means the v0.25 shape,
//      which reserves no extra slot at all.
//   2. NO SEEDABLE ROW HAS A COSIGNABLE TYPE. The only PendingTransaction this
//      lane can create is TestController#set_pending_signatures' hardcoded
//      "e2e_signature_probe" — a tx_type CosignPlan refuses — so the gate
//      rescues to 0 whatever the governance flag says.
//
// Retiring the fixture therefore takes BOTH: a tx_type parameter on
// set_pending_signatures AND governance on for the lane. Note that the gate
// is deliberately NOT `required_signatures - 2`: that arithmetic is
// governance-independent while the server's validation is not, and the two
// disagreeing is what made the page ask for a wallet #rebuild then refused 422.
//
// Everything the fixture DRIVES is the app's own: the button's onclick, the
// [data-cosign-controls] scoping, collectExtraCosigners, cosignTransaction, and
// the fetch. Only the element's markup is this spec's.

const TX_LABEL = "Settle Contest";
const PROBE_SLUG = "ptx-probe";
const COSIGN_BUTTON = "button[data-desktop-only-action]";

// The operator's Phantom, installed before any app script runs (cosignTransaction
// bails out early without window.solana.isPhantom, so without this the flow
// would refuse and the spec would assert nothing).
//
// ONE ACCOUNT IS ACTIVE AT A TIME AND NOTHING ADVANCES IT BUT switchAccount().
// That is deliberate: a stub that switched itself between signTransaction calls
// would satisfy every assertion below even against an implementation that never
// waited for the operator at all. Here the flow has to ASK — and the test is
// what answers.
async function installPhantomLab(page) {
  await page.addInitScript(() => {
    const lab = (window.__cosignLab = {
      queue: [],   // pubkeys in switch order; filled once web3.js is up
      active: 0,
      signed: [],  // the account that was active at each signTransaction call
      sign: null,  // installed with the keypairs, after load
      switchAccount() {
        lab.active = Math.min(lab.active + 1, lab.queue.length - 1);
      }
    });

    const activeKey = () => lab.queue[lab.active] || null;

    window.solana = {
      isPhantom: true,
      get publicKey() {
        const key = activeKey();
        return key ? { toBase58: () => key } : null;
      },
      connect: async () => ({ publicKey: window.solana.publicKey }),
      signTransaction: async (tx) => {
        lab.signed.push(activeKey());
        return lab.sign(tx, lab.active);
      }
    };
  });
}

// Build the wire the server would have returned from /rebuild: a THREE-signer
// transaction whose admin slot is already filled and whose two Phantom slots
// are empty. Built with the page's own web3.js so the bytes are the bytes the
// app will actually decode.
//
// secondWalletReturns "zeroed" makes the second wallet hand back a transaction
// with its own slot zero-filled — what a declined or mis-targeted signature
// looks like, and the case extractSignature's byte scan exists for.
async function buildThreeSignerWire(page, { secondWalletReturns } = {}) {
  return page.evaluate((mode) => {
    const lab = window.__cosignLab;
    const admin = solanaWeb3.Keypair.generate();  // the server's key
    const named = solanaWeb3.Keypair.generate();  // the named cosigner slot
    const extra = solanaWeb3.Keypair.generate();  // the extra remaining-account slot

    const tx = new solanaWeb3.Transaction();
    tx.recentBlockhash = solanaWeb3.Keypair.generate().publicKey.toBase58();
    tx.feePayer = admin.publicKey;
    tx.add(
      new solanaWeb3.TransactionInstruction({
        keys: [
          { pubkey: named.publicKey, isSigner: true, isWritable: false },
          { pubkey: extra.publicKey, isSigner: true, isWritable: false }
        ],
        programId: solanaWeb3.SystemProgram.programId,
        data: new Uint8Array([0])
      })
    );
    // The server signs as admin at build time; the browser owes the rest.
    tx.partialSign(admin);
    const bytes = tx.serialize({ requireAllSignatures: false, verifySignatures: false });
    const wire = btoa(String.fromCharCode.apply(null, new Uint8Array(bytes)));

    const keypairs = [named, extra];
    lab.queue = keypairs.map((k) => k.publicKey.toBase58());
    lab.active = 0;
    lab.signed = [];
    lab.sign = async (incoming, index) => {
      if (index === 1 && mode === "zeroed") {
        incoming.signatures.forEach((pair) => {
          if (pair.publicKey.equals(keypairs[1].publicKey)) {
            pair.signature = new Uint8Array(64);
          }
        });
        return incoming;
      }
      incoming.partialSign(keypairs[index]);
      return incoming;
    };

    // The real one awaits a network-guard modal this spec never clicks, which
    // would hang the flow rather than fail it. Installed after load so it wins
    // over the app's own definition.
    window.confirmSolanaNetworkIntent = async () => true;

    return {
      wire: wire,
      admin: admin.publicKey.toBase58(),
      named: lab.queue[0],
      extra: lab.queue[1]
    };
  }, secondWalletReturns);
}

// The treasury page renders its Co-sign buttons only for PENDING rows, and the
// e2e seed deletes every PendingTransaction.
async function seedPendingSignatures(request, live) {
  const response = await request.post("/test/set_pending_signatures", { form: { live, stale: 0 } });
  expect(response.ok()).toBe(true);
}

// What the modal is SHOWING, read from the store rather than from page text —
// the same reason e2e/admin_desktop_only.spec.js reads it there: this page also
// paints sentences into its desktop-only notice, and a getByText() assertion
// can be satisfied by the wrong one.
async function modalState(page) {
  return page.evaluate(() => {
    const m = window.Alpine && window.Alpine.store("solanaModal");
    return m ? { state: m.state, title: m.title, errorMessage: m.errorMessage } : null;
  });
}

// Start the flow WITHOUT blocking on it: the operator's account switch happens
// mid-flight, so the test has to stay free to make it happen.
async function startCosign(page, extras) {
  await page.evaluate(
    ({ slug, label, chosen }) => {
      window.__cosignDone = window.cosignTransaction(slug, label, chosen);
    },
    { slug: PROBE_SLUG, label: TX_LABEL, chosen: extras }
  );
}

test.beforeEach(async ({ request }) => await reseed(request));

// PUT THE TREASURY BACK EMPTY. `reseed` does NOT delete PendingTransactions and
// the lane runs one server with one worker, so a row seeded here survives into
// every later spec in the shard — and e2e/audit.spec.js asserts the treasury's
// EMPTY state. Same cleanup, and the same reason, as
// e2e/admin_desktop_only.spec.js.
test.afterEach(async ({ request }) => await seedPendingSignatures(request, 0));

test.describe("Treasury cosign with two wallets", () => {
  test("collects a signature from two different wallets onto one transaction @smoke", async ({ page }) => {
    await installPhantomLab(page);
    await loginAdmin(page);

    // Assigned after the page loads (the wire is built with the page's own
    // web3.js), and read by the route handler only once the flow runs.
    let fixture = null;
    const rebuildBodies = [];
    const broadcastBodies = [];

    await page.route("**/admin/pending_transactions/*/rebuild", async (route) => {
      rebuildBodies.push(route.request().postDataJSON());
      if (!fixture) {
        await route.fulfill({
          status: 500,
          contentType: "application/json",
          body: JSON.stringify({ error: "spec bug: the wire fixture was not built before the flow ran" })
        });
        return;
      }
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          status: "rebuilt",
          serialized_tx: fixture.wire,
          required_signatures: 3,
          // The signing plan travels WITH the bytes, which is what the browser
          // builds its signer queue from.
          cosigner_address: fixture.named,
          extra_cosigners: [fixture.extra]
        })
      });
    });

    await page.route("**/admin/pending_transactions/*/broadcast", async (route) => {
      broadcastBodies.push(route.request().postDataJSON());
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ status: "confirmed", tx_signature: "CosignedThreeWays1111111111" })
      });
    });

    await page.goto("/admin/pending_transactions");

    // Both modules parsed and installed their globals. No server-side tier can
    // tell a loaded script from one that threw on import, and cosign.js reaches
    // through window.cosignSignatures with no guard.
    const installed = await page.evaluate(() => [
      typeof window.cosignTransaction,
      window.cosignSignatures && typeof window.cosignSignatures.collect
    ]);
    expect(installed).toEqual(["function", "function"]);

    fixture = await buildThreeSignerWire(page);
    expect(fixture.named).not.toBe(fixture.extra);

    await startCosign(page, [fixture.extra]);

    // 1. THE FLOW STOPS AND ASKS. Phantom is still on the first wallet, so the
    //    second signature cannot be collected yet — and the only correct
    //    behaviour is to say which account is needed and wait for it. Nothing
    //    but this test advances the account, so reaching this state is proof
    //    the flow waited rather than signing twice with whoever was selected.
    await expect
      .poll(() => modalState(page).then((m) => m && m.title), { timeout: 10_000 })
      .toBe("Switch Phantom Account");

    // The operator walks to the extension and picks the second wallet.
    await page.evaluate(() => window.__cosignLab.switchAccount());

    await expect.poll(() => broadcastBodies.length, { timeout: 10_000 }).toBe(1);
    await page.evaluate(() => window.__cosignDone);

    // 2. THE BUILD RESERVED THE EXTRA SLOT. The slots are part of the message,
    //    so a rebuild that omits them produces a transaction already short
    //    before Phantom is ever opened.
    expect(rebuildBodies).toHaveLength(1);
    expect(rebuildBodies[0].extra_cosigners).toEqual([fixture.extra]);

    // 3. TWO signTransaction CALLS, FROM TWO DIFFERENT ACCOUNTS. The old code
    //    called it once; a switch-blind rewrite would call it twice with the
    //    same account.
    const signedBy = await page.evaluate(() => window.__cosignLab.signed);
    expect(signedBy).toEqual([fixture.named, fixture.extra]);

    // 4. THE BROADCAST NAMES BOTH WALLETS — and names the SERVER's plan rather
    //    than whatever account Phantom is left holding. By now the extension is
    //    on the SECOND wallet, so reading provider.publicKey here would record
    //    the wrong wallet as the named cosigner on a payout's audit row.
    const body = broadcastBodies[0];
    expect(body.cosigner_address).toBe(fixture.named);
    expect(body.extra_cosigners).toEqual([fixture.extra]);
    const stillSelected = await page.evaluate(() => window.solana.publicKey.toBase58());
    expect(stillSelected).toBe(fixture.extra);
    expect(body.cosigner_address).not.toBe(stillSelected);

    // 5. ONE TRANSACTION, THREE VALID SIGNATURES. The signatures were made
    //    against three SEPARATE decodes of the same bytes and merged at the
    //    end, so this is the assertion that the merge actually holds: web3.js
    //    verifies each signature against the merged message, and two distinct
    //    wallets occupy two distinct slots.
    const merged = await page.evaluate((b64) => {
      const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
      const tx = window.solanaWeb3.Transaction.from(bytes);
      return {
        verifies: tx.verifySignatures(),
        slots: tx.signatures.map((pair) => ({
          pubkey: pair.publicKey.toBase58(),
          signature: pair.signature ? Array.from(pair.signature).join(",") : null
        }))
      };
    }, body.signed_tx);

    expect(merged.verifies).toBe(true);
    expect(merged.slots).toHaveLength(3);
    expect(merged.slots.filter((s) => s.signature)).toHaveLength(3);

    const namedSlot = merged.slots.find((s) => s.pubkey === fixture.named);
    const extraSlot = merged.slots.find((s) => s.pubkey === fixture.extra);
    const adminSlot = merged.slots.find((s) => s.pubkey === fixture.admin);
    expect(namedSlot && namedSlot.signature).toBeTruthy();
    expect(extraSlot && extraSlot.signature).toBeTruthy();
    expect(adminSlot && adminSlot.signature).toBeTruthy();
    // Three DISTINCT signatures — not one wallet's signature copied into two
    // slots, which is what DuplicateSigner rejects on-chain.
    expect(new Set(merged.slots.map((s) => s.signature)).size).toBe(3);
  });

  test("carries the wallet the clicked ROW's own select names into the rebuild", async ({ page, request }) => {
    await installPhantomLab(page);
    await seedPendingSignatures(request, 2);
    await loginAdmin(page);

    const rebuilds = [];
    await page.route("**/admin/pending_transactions/*/rebuild", async (route) => {
      rebuilds.push({ url: route.request().url(), body: route.request().postDataJSON() });
      // A deliberately unusable body, as in e2e/cosign_fresh_transaction.spec.js:
      // what the page ASKS the server for is the whole observable here.
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ status: "rebuilt", serialized_tx: "" })
      });
    });

    await page.goto("/admin/pending_transactions");
    await page.evaluate(() => {
      window.confirmSolanaNetworkIntent = async () => true;
    });

    // A FLOOR, NOT AN EQUALITY. `reseed` does not delete PendingTransactions
    // and set_pending_signatures only clears its OWN probe rows, so a row some
    // earlier spec in the shard created would make an equality assertion red
    // for a reason that has nothing to do with this behaviour. The index orders
    // created_at DESC and these two were just made, so they are indices 0 and 1
    // whatever else is on the page.
    const rows = page.locator("[data-cosign-controls]");
    await expect(rows.nth(1)).toBeVisible();
    expect(await rows.count()).toBeGreaterThanOrEqual(2);

    // THE SELECT IS THIS SPEC'S FIXTURE — see the file header for why it cannot
    // be rendered in this lane. A DIFFERENT wallet per row, because the defect
    // collectExtraCosigners exists to stop is a DOCUMENT-WIDE query handing
    // every row the FIRST row's wallet. That failure is silent right up to the
    // point the chain answers DuplicateSigner or Unauthorized on a payout, so
    // one row would prove nothing.
    const wallets = await page.evaluate(() => {
      const chosen = [];
      document.querySelectorAll("[data-cosign-controls]").forEach((scope) => {
        const wallet = window.solanaWeb3.Keypair.generate().publicKey.toBase58();
        chosen.push(wallet);
        const select = document.createElement("select");
        select.setAttribute("data-extra-cosigner", "");
        const option = document.createElement("option");
        option.value = wallet;
        option.textContent = wallet;
        select.appendChild(option);
        scope.prepend(select);
      });
      return chosen;
    });
    expect(wallets[0]).not.toBe(wallets[1]);

    // Read off the button about to be clicked rather than indexed out of a
    // document-wide list: a non-pending row renders a [data-cosign-controls]
    // with NO button inside it, so the two lists can disagree on what "row 1"
    // means — which is the same indexing mistake this test exists to catch.
    const target = rows.nth(1).locator(COSIGN_BUTTON);
    const targetSlug = await target.getAttribute("data-tx-slug");
    expect(targetSlug).toBeTruthy();

    // Clicked, not invoked: the button's own onclick is the thing that composes
    // collectExtraCosigners(this) into cosignTransaction's third argument, and
    // invoking the global directly would skip exactly that seam.
    await target.click();

    await expect.poll(() => rebuilds.length, { timeout: 5_000 }).toBe(1);

    // The SECOND row's slug and the SECOND row's wallet travelled together.
    expect(rebuilds[0].url).toContain("/admin/pending_transactions/" + targetSlug + "/rebuild");
    expect(rebuilds[0].body.extra_cosigners).toEqual([wallets[1]]);
    expect(rebuilds[0].body.extra_cosigners).not.toContain(wallets[0]);
  });

  test("refuses to broadcast when a wallet hands back an unfilled signature slot", async ({ page }) => {
    await installPhantomLab(page);
    await loginAdmin(page);

    let fixture = null;
    const broadcasts = [];

    await page.route("**/admin/pending_transactions/*/rebuild", async (route) => {
      if (!fixture) {
        await route.fulfill({
          status: 500,
          contentType: "application/json",
          body: JSON.stringify({ error: "spec bug: the wire fixture was not built before the flow ran" })
        });
        return;
      }
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          status: "rebuilt",
          serialized_tx: fixture.wire,
          required_signatures: 3,
          cosigner_address: fixture.named,
          extra_cosigners: [fixture.extra]
        })
      });
    });

    await page.route("**/admin/pending_transactions/*/broadcast", async (route) => {
      broadcasts.push(route.request().postDataJSON());
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ status: "confirmed", tx_signature: "ShouldNeverBeReached11111" })
      });
    });

    await page.goto("/admin/pending_transactions");

    // The SECOND wallet is the one that comes back empty, which is the harder
    // case: a partial collection already succeeded, so the only thing standing
    // between this and a chain that answers 6046 InsufficientSigners is the
    // module refusing to merge what it does not have.
    fixture = await buildThreeSignerWire(page, { secondWalletReturns: "zeroed" });

    await startCosign(page, [fixture.extra]);

    await expect
      .poll(() => modalState(page).then((m) => m && m.title), { timeout: 10_000 })
      .toBe("Switch Phantom Account");
    await page.evaluate(() => window.__cosignLab.switchAccount());

    await expect
      .poll(() => modalState(page).then((m) => m && m.state), { timeout: 10_000 })
      .toBe("error");
    await page.evaluate(() => window.__cosignDone);

    // IT NAMES THE WALLET. The chain's own answer names nobody, which is what
    // made this failure cost hours; the refusal has to say which account was
    // selected when the slot came back empty.
    const failure = await modalState(page);
    expect(failure.title).toBe(TX_LABEL + " Failed");
    expect(failure.errorMessage).toMatch(/Phantom returned no signature for/i);
    expect(failure.errorMessage).toContain(fixture.extra);

    // AND IT STOPS THERE. A zero-filled slot is present in the signatures array
    // but is not a signature, and treating the two as the same fact is exactly
    // how a transaction reaches the chain one short.
    expect(broadcasts).toHaveLength(0);

    // The first wallet really did sign — this is a refusal at the SECOND
    // signature, not a flow that never got started.
    const signedBy = await page.evaluate(() => window.__cosignLab.signed);
    expect(signedBy).toEqual([fixture.named, fixture.extra]);
  });
});
