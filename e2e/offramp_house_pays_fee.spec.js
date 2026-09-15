const { test, expect } = require("@playwright/test");

// [e2e] The Phantom cash-out wire is fee-paid by the HOUSE, so the browser has
// to hand it back for a cosign BEFORE it broadcasts.
//
// WHY A BROWSER IS THE ONLY WITNESS. Since phantom-cashout-needs-sol the wire
// carries TWO signer slots — the admin as fee payer and the player as transfer
// authority — and Phantom only ever fills the second. Everything that follows
// lives in web3.js semantics no server-side tier can reach:
//
//   · `Transaction.serialize()` THROWS when a required signature slot is empty.
//     The page must pass `{ requireAllSignatures: false }`, and there is no
//     String assertion that can tell the two calls apart — the source looks
//     fine either way, and the failure is a rejected promise in the wallet step.
//     Here it is decisive: with a plain serialize() the flow dies before the
//     cosign POST, so the cosign assertion below simply never sees its request.
//   · the bytes that reach the cluster must be the COSIGNED ones. A page that
//     broadcast its own Phantom-signed copy would send a wire with an empty fee
//     payer slot — rejected by the cluster, and indistinguishable from a
//     network fault from the server's side.
//
// Phantom is stubbed (a real signature needs the extension) and it returns the
// transaction unsigned, which is the harsher case: EVERY signer slot is empty,
// so a serialize() that demanded complete signatures could not possibly pass.
// The server halves are covered by test/services/solana/vault_offramp_fee_payer_test.rb
// and test/controllers/cdp/offramp_sends_controller_test.rb.
//
// No seed data: every request this flow makes is intercepted, so the spec owns
// its own fixtures and asserts nothing about the database.

test.describe("Phantom cash-out", () => {
  test("cosigns with the house before broadcasting @smoke", async ({ page }) => {
    await page.addInitScript(() => {
      window.__cashoutWallet = null;
      window.solana = {
        isPhantom: true,
        get publicKey() {
          return { toBase58: () => window.__cashoutWallet };
        },
        connect: async () => ({ publicKey: { toBase58: () => window.__cashoutWallet } }),
        // Returns the transaction UNSIGNED — see the header. This is what makes
        // the serialize() call the thing under test.
        signTransaction: async (tx) => tx
      };
    });
    // NB: the network-intent and confirmation stubs are installed AFTER the page
    // loads, not here — app modules define both, and an addInitScript value is
    // set before those run and would simply be overwritten. The real
    // confirmSolanaNetworkIntent awaits a modal the spec never clicks, which
    // would hang the flow rather than fail it. window.authedFetch is left ALONE
    // on purpose: it passes non-401/429 responses straight through, and every
    // response here is a fulfilled 200.

    await page.goto("/");

    // 1. The module parsed and installed its global. No server-side tier can
    //    tell a loaded script from one that threw on import.
    const installed = await page.evaluate(() => typeof window.buildAndSendOfframpUsdcTransfer);
    expect(installed).toBe("function");

    // Two DISTINCT real wires, built with the page's own web3.js: the one the
    // server "prepared" (house as fee payer, every slot empty) and the one the
    // cosign "returns". Distinct so the broadcast assertion can tell which set
    // of bytes actually reached the cluster.
    const fixture = await page.evaluate(() => {
      const build = () => {
        const house = solanaWeb3.Keypair.generate();
        const wallet = solanaWeb3.Keypair.generate();
        const tx = new solanaWeb3.Transaction();
        tx.recentBlockhash = solanaWeb3.Keypair.generate().publicKey.toBase58();
        tx.feePayer = house.publicKey;
        tx.add(
          new solanaWeb3.TransactionInstruction({
            keys: [{ pubkey: wallet.publicKey, isSigner: true, isWritable: false }],
            programId: solanaWeb3.SystemProgram.programId,
            data: new Uint8Array([1, 2, 3])
          })
        );
        const bytes = tx.serialize({ requireAllSignatures: false, verifySignatures: false });
        return {
          wallet: wallet.publicKey.toBase58(),
          b64: btoa(String.fromCharCode.apply(null, new Uint8Array(bytes)))
        };
      };
      const prepared = build();
      const cosigned = build();
      window.__cashoutWallet = prepared.wallet;
      // Installed here so they win over the app's own definitions.
      window.confirmSolanaNetworkIntent = async () => true;
      window.pollConfirmation = async () => true;
      return { prepared: prepared.b64, cosigned: cosigned.b64, wallet: prepared.wallet };
    });
    expect(fixture.prepared).not.toBe(fixture.cosigned);

    const order = [];
    const cosignBodies = [];

    await page.route("**/cdp/offramp/prepare_send", async (route) => {
      order.push("prepare");
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          serialized_tx: fixture.prepared,
          wallet_address: fixture.wallet,
          destination_token_account: "DestinationTokenAccount1111111111111111111",
          amount_base_units: 19000000
        })
      });
    });

    await page.route("**/cdp/offramp/cosign_send", async (route) => {
      order.push("cosign");
      cosignBodies.push(route.request().postDataJSON());
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          signed_tx: fixture.cosigned,
          tx_signature: "HouseCosignedSignature111",
          wallet_address: fixture.wallet
        })
      });
    });

    await page.route("**/cdp/offramp/sent", async (route) => {
      order.push("sent");
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ ok: true, status: "sent" })
      });
    });

    // The cluster. Answer by JSON-RPC method so the client library can do
    // whatever bookkeeping calls it likes around the send.
    const rpcUrl = await page.evaluate(
      () => document.body.dataset.solanaRpcUrl || "https://api.devnet.solana.com"
    );
    const broadcastPayloads = [];
    await page.route(rpcUrl + "**", async (route) => {
      const body = route.request().postDataJSON() || {};
      let result = null;
      if (body.method === "sendTransaction") {
        order.push("broadcast");
        broadcastPayloads.push(body.params && body.params[0]);
        result = "BroadcastSignature1111111111111111111111111";
      } else if (body.method === "getLatestBlockhash") {
        result = { context: { slot: 1 }, value: { blockhash: "11111111111111111111111111111111", lastValidBlockHeight: 100 } };
      } else if (body.method === "getSignatureStatuses") {
        result = { context: { slot: 1 }, value: [{ slot: 1, confirmations: 1, err: null, confirmationStatus: "confirmed" }] };
      }
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ jsonrpc: "2.0", result: result, id: body.id || 1 })
      });
    });

    const signature = await page.evaluate(async () => {
      return await window.buildAndSendOfframpUsdcTransfer({ partnerUserRef: "tm-cashout-probe" });
    });

    // 2. The cosign hop happened at all — which it cannot if the page serialized
    //    the Phantom-signed wire with a plain serialize(): that throws on the
    //    empty house slot and the flow dies before this request is ever made.
    expect(cosignBodies.length).toBe(1);
    expect(cosignBodies[0].partner_user_ref).toBe("tm-cashout-probe");
    expect(typeof cosignBodies[0].signed_tx).toBe("string");
    expect(cosignBodies[0].signed_tx.length).toBeGreaterThan(0);

    // 3. The bytes that reached the cluster are the COSIGNED ones. A page that
    //    broadcast its own copy would send a wire with no house signature.
    expect(broadcastPayloads.length).toBe(1);
    expect(broadcastPayloads[0]).toBe(fixture.cosigned);
    expect(broadcastPayloads[0]).not.toBe(fixture.prepared);

    // 4. Order: nothing is broadcast before the house has signed.
    expect(order.indexOf("cosign")).toBeGreaterThan(-1);
    expect(order.indexOf("broadcast")).toBeGreaterThan(order.indexOf("cosign"));
    expect(order.indexOf("sent")).toBeGreaterThan(order.indexOf("broadcast"));

    expect(signature).toBe("BroadcastSignature1111111111111111111111111");
  });
});
