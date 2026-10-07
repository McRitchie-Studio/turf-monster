/**
 * Route interceptors for Solana onchain endpoints.
 *
 * Intercepts:
 *   - POST /contests/:id/prepare_entry         (needs Solana::Vault / devnet)
 *   - POST /contests/:id/confirm_onchain_entry  (needs entry_id from mocked prepare)
 *   - Solana JSON-RPC (https://api.devnet.solana.com)
 *
 * Also patches solanaWeb3.Connection prototype so sendRawTransaction and
 * confirmTransaction return instantly (avoids WebSocket subscriptions).
 */

const { MOCK_PUBKEY_B58 } = require("./phantom-mock");

const MOCK_TX_SIG =
  "MockTxSignature" + "1".repeat(74); // ~88 chars, valid base58

/**
 * Compute a minimal valid serialized Solana Transaction in the browser.
 * Requires solanaWeb3 to be loaded on the page.
 */
async function computeMockTransaction(page, pubkeyB58) {
  return await page.evaluate((pubkey) => {
    const tx = new solanaWeb3.Transaction();
    tx.recentBlockhash = "11111111111111111111111111111111";
    tx.feePayer = new solanaWeb3.PublicKey(pubkey);
    const bytes = tx.serialize({
      requireAllSignatures: false,
      verifySignatures: false,
    });
    return btoa(String.fromCharCode(...bytes));
  }, pubkeyB58);
}

/**
 * Set up all onchain route interceptions for a page.
 * Call BEFORE navigating to pages that trigger onchain flows.
 */
async function setupOnchainMocks(page) {
  // --- Patch solanaWeb3.Connection prototype ---
  // Avoids real RPC calls and WebSocket subscriptions for confirmTransaction.
  await page.addInitScript((mockTxSig) => {
    let _patched = false;
    const timer = setInterval(() => {
      if (_patched) return;
      const sw = window.solanaWeb3;
      if (sw && sw.Connection && sw.Connection.prototype) {
        _patched = true;
        clearInterval(timer);

        sw.Connection.prototype.sendRawTransaction = async function () {
          return mockTxSig;
        };
        sw.Connection.prototype.confirmTransaction = async function () {
          return { context: { slot: 1 }, value: { err: null } };
        };
      }
    }, 5);
    setTimeout(() => clearInterval(timer), 60000);
  }, MOCK_TX_SIG);

  // --- Mock tx cache (computed lazily via page.evaluate) ---
  let mockTxCache = null;

  async function getMockTx() {
    if (!mockTxCache) {
      mockTxCache = await computeMockTransaction(page, MOCK_PUBKEY_B58);
    }
    return mockTxCache;
  }

  // --- API route interceptions ---

  // prepare_entry — server builds partial-signed tx (needs devnet)
  await page.route("**/contests/*/prepare_entry", async (route) => {
    const mockTx = await getMockTx();
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        success: true,
        serialized_tx: mockTx,
        entry_id: 999,
        entry_pda: "MockEntryPDA1111111111111111111111111111111",
      }),
    });
  });

  // confirm_onchain_entry — reads seeds from devnet
  await page.route("**/contests/*/confirm_onchain_entry", async (route) => {
    const url = route.request().url();
    const contestSlug = url.match(/contests\/([^/]+)/)?.[1];
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        success: true,
        redirect: `/contests/${contestSlug}`,
        tx_signature: MOCK_TX_SIG,
        seeds_earned: 65,
        seeds_total: 65,
        seeds_level: 1,
      }),
    });
  });

  // --- Solana JSON-RPC fallback (safety net) ---
  await page.route("**/api.devnet.solana.com**", async (route) => {
    let body = {};
    try {
      body = JSON.parse(route.request().postData() || "{}");
    } catch {
      // non-JSON request — just fulfill
    }
    const method = body.method;

    let result;
    if (method === "sendTransaction") {
      result = MOCK_TX_SIG;
    } else if (method === "confirmTransaction") {
      result = { value: { err: null } };
    } else if (method === "getSignatureStatuses") {
      result = {
        value: [{ confirmationStatus: "confirmed", err: null }],
      };
    } else if (method === "getLatestBlockhash") {
      result = {
        value: {
          blockhash: "11111111111111111111111111111111",
          lastValidBlockHeight: 999999,
        },
      };
    } else {
      result = null;
    }

    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: body.id || 1,
        result,
      }),
    });
  });
}

module.exports = { setupOnchainMocks, computeMockTransaction };
