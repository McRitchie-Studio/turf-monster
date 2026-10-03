const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// [e2e] The Phantom lock route carries the whole capability the server-signed
// path gave up: an ARBITRARY moment, and NO LOCK AT ALL.
//
// WHY A BROWSER IS THE ONLY WITNESS. Every tier this change's `backend` shape
// demands renders to a String, and the logic under test never reaches a
// response body. `contestLockPicker.pickedUnix()` turns a date and a time the
// operator picked into Unix seconds — a timezone slip there does not change one
// byte of markup, it changes a CONTEST DEADLINE, which is money in both
// directions. And `clearContestLockViaPhantom` sends `lock_timestamp: 0`, a
// value JavaScript is happy to treat as absent; a String assertion cannot see
// whether the key survived JSON.stringify.
//
// WHAT IS DELIBERATELY NOT HERE. The edit page's hidden-field change is asserted
// at the String tier instead (contests_pending_visibility_test.rb), because that
// one IS about the bytes the server emits, and the e2e seed deliberately nulls
// every contest's onchain_contest_id (e2e/seed.rb) so no verified contest exists
// to render here. Inventing one would put an on-chain row into the shared e2e
// database that the seed goes out of its way to avoid.
//
// Phantom is stubbed. This spec is about what the page asks the server for
// before a wallet signs anything; the signing half needs a real extension.
test.beforeEach(async ({ request }) => await reseed(request));

test.describe("Phantom contest lock", () => {
  // A desktop Phantom, installed before any app script runs. The flow bails at
  // `provider.isPhantom` and again at `resp.publicKey.toBase58()`, so without
  // both of these the spec would assert nothing and still pass.
  async function stubDesktopPhantom(page) {
    await page.addInitScript(() => {
      const key = { toBase58: () => "LockSpec1111111111111111111111111111111111" };
      window.solana = {
        isPhantom: true,
        publicKey: key,
        connect: async () => ({ publicKey: key }),
        signTransaction: async (tx) => tx,
      };
    });
  }

  // Capture the prepare request and STOP there: everything under test has
  // already happened by the time it is sent, and going further would need a
  // real serialized transaction from the chain.
  async function capturePrepare(page) {
    const bodies = [];
    await page.route("**/contests/*/prepare_lock_time", async (route) => {
      bodies.push(JSON.parse(route.request().postData() || "{}"));
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ success: false, error: "stubbed after the request under test" }),
      });
    });
    return bodies;
  }

  async function openAdminPage(page) {
    await stubDesktopPhantom(page);
    const bodies = await capturePrepare(page);
    await loginAdmin(page);
    await page.goto("/contests");
    // The session store holds the wallet the page expects to sign. It is unset
    // in this stack, but if it ever carries an address the flow refuses with
    // "Wrong Wallet" and sends nothing — which would look like a passing
    // assertion about an empty array.
    await page.evaluate(() => {
      const s = window.Alpine && window.Alpine.store("session");
      if (s) s.address = null;
    });
    return bodies;
  }

  test("the picker hands Phantom an absolute moment, not a relative offset @smoke", async ({ page }) => {
    const bodies = await openAdminPage(page);

    // The module PARSED and installed its global. An import that throws leaves
    // the button inert with no server-side symptom at all.
    expect(await page.evaluate(() => typeof window.lockContestAtViaPhantom)).toBe("function");

    const picked = await page.evaluate(() => {
      const picker = window.contestLockPicker({ slug: "lock-spec-contest", onchain: true });
      picker.lockDate = "2026-12-25";
      picker.lockTime = "16:25";
      const ts = picker.pickedUnix();
      picker.lockViaPhantom();
      return ts;
    });

    // THE DEADLINE THE OPERATOR ACTUALLY PICKED. Read back through the browser's
    // own clock: 16:25 chosen in front of the tz label the view prints must be
    // 16:25 when the number is turned back into a date. An hour of drift here is
    // an hour of entries against known results.
    const wall = await page.evaluate((ts) => {
      const d = new Date(ts * 1000);
      return [d.getHours(), d.getMinutes()];
    }, picked);
    expect(wall).toEqual([16, 25]);

    // Far outside the 0..3600s the relative form clamps to — the reschedule the
    // old server-signed path could express and a relative-only route could not.
    expect(picked - Math.floor(Date.now() / 1000)).toBeGreaterThan(3600);

    await expect.poll(() => bodies.length).toBe(1);
    expect(bodies[0]).toEqual({ lock_timestamp: picked });
  });

  test("clearing the lock sends a zero the client does not swallow", async ({ page }) => {
    const bodies = await openAdminPage(page);

    await page.evaluate(() => window.clearContestLockViaPhantom("lock-spec-contest"));

    await expect.poll(() => bodies.length).toBe(1);
    // toEqual, not a truthy check: `0` is the program's spelling of "no lock",
    // and the failure mode this pins is JavaScript dropping it as falsy — the
    // key vanishing, or arriving as null, which the server would read as a
    // malformed call rather than a clear.
    expect(bodies[0]).toEqual({ lock_timestamp: 0 });
  });

  // THE SERVER BROADCASTS, NOT THE PAGE (server-broadcasts-contest-lock).
  //
  // Production 2026-10-03: this flow called connection.sendRawTransaction
  // against `data-solana-rpc-url`, which on mainnet is the free public RPC, and
  // died as `403 Access forbidden`. Now the signed wire goes to
  // confirm_lock_time as `signed_tx`. Only a live browser can show that: the
  // prepare answer is a REAL wire the page must parse, hand to Phantom and
  // re-serialize with the fee payer's slot still empty (a strict serialize
  // throws AFTER the operator approved), and the absence of an RPC call is a
  // fact about the network, not the markup.
  test("the signed wire is POSTed to the server and the page never calls an RPC", async ({ page }) => {
    await stubDesktopPhantom(page);

    const rpcCalls = [];
    page.on("request", (req) => {
      const body = req.postData() || "";
      if (/"jsonrpc"/.test(body) || /solana\.com|helius|quiknode|rpcpool/.test(req.url())) rpcCalls.push(req.url());
    });

    let prepared = null;
    await page.route("**/contests/*/prepare_lock_time", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ success: true, serialized_tx: prepared, lock_timestamp: 1798230300 }),
      });
    });
    const confirms = [];
    await page.route("**/contests/*/confirm_lock_time", async (route) => {
      confirms.push(JSON.parse(route.request().postData() || "{}"));
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ success: false, error: "stubbed after the request under test" }),
      });
    });

    await loginAdmin(page);
    await page.goto("/contests");
    await page.evaluate(() => {
      const s = window.Alpine && window.Alpine.store("session");
      if (s) s.address = null;
    });

    // A real, UNSIGNED two-signer wire, built by the page's own web3: a fee
    // payer the server will fill and the operator's Phantom key.
    prepared = await page.evaluate(() => {
      const w3 = window.solanaWeb3;
      const feePayer = w3.Keypair.generate().publicKey;
      const operator = w3.Keypair.generate().publicKey;
      const tx = new w3.Transaction({ feePayer, recentBlockhash: w3.Keypair.generate().publicKey.toBase58() });
      tx.add(new w3.TransactionInstruction({
        programId: w3.Keypair.generate().publicKey,
        keys: [{ pubkey: operator, isSigner: true, isWritable: true }],
        data: new Uint8Array([1, 2, 3]),
      }));
      return btoa(String.fromCharCode.apply(null, tx.serialize({ requireAllSignatures: false, verifySignatures: false })));
    });

    await page.evaluate(() => window.lockContestAtViaPhantom("lock-spec-contest", 1798230300));

    await expect.poll(() => confirms.length).toBe(1);
    expect(confirms[0].lock_timestamp).toBe(1798230300);
    expect(confirms[0].tx_signature).toBeUndefined();
    // The page re-serialized the very wire it was handed: same message bytes.
    const sameMessage = await page.evaluate(([a, b]) => {
      const w3 = window.solanaWeb3;
      const dec = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
      const m1 = w3.Transaction.from(dec(a)).serializeMessage();
      const m2 = w3.Transaction.from(dec(b)).serializeMessage();
      return m1.length === m2.length && m1.every((v, i) => v === m2[i]);
    }, [prepared, confirms[0].signed_tx]);
    expect(sameMessage).toBe(true);
    expect(rpcCalls).toEqual([]);
  });

  // THE CONTROL. The quick buttons on the contest page still send a RELATIVE
  // offset, so the two specs above are pinning a body shape chosen per entry
  // point rather than one hardcoded for every caller.
  test("the quick lock buttons still send a relative offset", async ({ page }) => {
    const bodies = await openAdminPage(page);

    await page.evaluate(() => window.lockContestViaPhantom("lock-spec-contest", 60));

    await expect.poll(() => bodies.length).toBe(1);
    expect(bodies[0]).toEqual({ in_seconds: 60 });
  });
});
