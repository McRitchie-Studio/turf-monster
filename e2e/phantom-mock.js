/**
 * Phantom wallet mock for Playwright E2E tests.
 *
 * Injects a fake `window.phantom.solana` provider that uses real Ed25519
 * signing via tweetnacl CDN — so the server's `verify_solana_signature!`
 * works unchanged.
 *
 * Usage:
 *   const { setupPhantomMock, MOCK_PUBKEY_B58 } = require('./phantom-mock');
 *   await setupPhantomMock(page);              // seed byte 1 = alex
 *   await setupPhantomMock(page, { seedByte: 2 }); // different wallet
 *   await setupPhantomMock(page, { walletStandard: true }); // late WS adapter
 */

// Pre-computed from deterministic seed (last byte = 1)
const MOCK_PUBKEY_B58 = "6ASf5EcmmEHTgDJ4X4ZT5vT6iHVJBXPg5AN5YoTCpGWt";

/**
 * Inject Phantom mock into the page via addInitScript.
 * Runs before any page scripts — Alpine's walletAvailable check passes immediately.
 */
async function setupPhantomMock(page, { seedByte = 1, walletStandard = false } = {}) {
  await page.addInitScript(({ initialSeedByte, useWalletStandard }) => {
    let currentSeedByte = Number(localStorage.getItem("phantomMockSeedByte")) || initialSeedByte;

    // --- Base58 encoder (Bitcoin alphabet) ---
    const B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
    function encodeBase58(bytes) {
      let n = BigInt(0);
      for (const b of bytes) n = n * 256n + BigInt(b);
      let r = "";
      while (n > 0n) {
        r = B58[Number(n % 58n)] + r;
        n = n / 58n;
      }
      for (const b of bytes) {
        if (b !== 0) break;
        r = "1" + r;
      }
      return r || "1";
    }

    // --- Lazy tweetnacl loader ---
    let _keypair = null;
    let _naclLoaded = false;

    function loadTweetnacl() {
      if (_naclLoaded) return Promise.resolve();
      if (typeof nacl !== "undefined" && nacl.sign) {
        _naclLoaded = true;
        return Promise.resolve();
      }
      return new Promise((resolve, reject) => {
        const s = document.createElement("script");
        s.src = "https://cdn.jsdelivr.net/npm/tweetnacl@1.0.3/nacl-fast.min.js";
        s.onload = () => {
          _naclLoaded = true;
          resolve();
        };
        s.onerror = reject;
        (document.head || document.documentElement).appendChild(s);
      });
    }

    async function getKeypair() {
      if (_keypair) return _keypair;
      await loadTweetnacl();
      const seed = new Uint8Array(32);
      seed[31] = currentSeedByte;
      _keypair = nacl.sign.keyPair.fromSeed(seed);
      return _keypair;
    }

    // --- Public key helper ---
    function makePublicKey(bytes) {
      return {
        toBytes: () => bytes,
        toBase58: () => encodeBase58(bytes),
        toString: () => encodeBase58(bytes),
      };
    }

    // --- Phantom provider mock ---
    const listeners = {};
    const standardChangeListeners = [];
    let standardAccount = null;
    function emit(event, value) {
      (listeners[event] || []).forEach((callback) => callback(value));
    }

    function makeStandardAccount(bytes) {
      return {
        address: encodeBase58(bytes),
        publicKey: bytes,
        chains: ["solana:devnet", "solana:mainnet"],
        features: ["solana:signMessage"],
      };
    }

    const solana = {
      isPhantom: true,
      isConnected: false,
      publicKey: null,

      async connect() {
        const kp = await getKeypair();
        this.isConnected = true;
        this.publicKey = makePublicKey(kp.publicKey);
        return { publicKey: this.publicKey };
      },

      async disconnect() {
        this.isConnected = false;
        this.publicKey = null;
      },

      async signMessage(message) {
        const kp = await getKeypair();
        const signature = nacl.sign.detached(message, kp.secretKey);
        return { signature };
      },

      async signTransaction(tx) {
        const kp = await getKeypair();
        // solanaWeb3 is loaded from the page's CDN
        const solKp = solanaWeb3.Keypair.fromSecretKey(kp.secretKey);
        tx.partialSign(solKp);
        return tx;
      },

      on(event, callback) {
        listeners[event] ||= [];
        listeners[event].push(callback);
      },

      off(event, callback) {
        listeners[event] = (listeners[event] || []).filter((item) => item !== callback);
      },

      async __switchAccount(nextSeedByte, { transientNull = false, emitEvent = true } = {}) {
        if (transientNull && emitEvent) {
          if (useWalletStandard) {
            standardChangeListeners.forEach((callback) => callback({ accounts: [] }));
          } else {
            emit("accountChanged", null);
          }
        }
        await new Promise((resolve) => setTimeout(resolve, 25));
        currentSeedByte = nextSeedByte;
        localStorage.setItem("phantomMockSeedByte", String(nextSeedByte));
        _keypair = null;
        const kp = await getKeypair();
        this.isConnected = true;
        this.publicKey = makePublicKey(kp.publicKey);
        standardAccount = makeStandardAccount(kp.publicKey);
        if (emitEvent) {
          if (useWalletStandard) {
            standardChangeListeners.forEach((callback) => callback({ accounts: [standardAccount] }));
          } else {
            emit("accountChanged", this.publicKey);
          }
        }
      },
    };

    window.phantom = { solana };

    if (useWalletStandard) {
      const wallet = {
        name: "Phantom",
        chains: ["solana:devnet", "solana:mainnet"],
        get accounts() { return standardAccount ? [standardAccount] : []; },
        features: {
          "standard:connect": {
            version: "1.0.0",
            connect: async () => {
              const kp = await getKeypair();
              standardAccount = makeStandardAccount(kp.publicKey);
              return { accounts: [standardAccount] };
            },
          },
          "standard:disconnect": {
            version: "1.0.0",
            disconnect: async () => { standardAccount = null; },
          },
          "standard:events": {
            version: "1.0.0",
            on: (event, callback) => {
              if (event === "change") standardChangeListeners.push(callback);
              return () => {
                const index = standardChangeListeners.indexOf(callback);
                if (index >= 0) standardChangeListeners.splice(index, 1);
              };
            },
          },
          "solana:signMessage": {
            version: "1.0.0",
            signMessage: async ({ message }) => {
              const kp = await getKeypair();
              return [{ signature: nacl.sign.detached(message, kp.secretKey) }];
            },
          },
        },
      };

      // Model Phantom's real lifecycle: its legacy injected provider exists
      // first, then Wallet Standard registers the adapter that the hub uses.
      window.addEventListener("wallet-standard:app-ready", (event) => {
        setTimeout(() => event.detail.register(wallet), 150);
      });
    }

    // --- Inject dummy CSRF meta tag ---
    // Test env has allow_forgery_protection=false so Rails skips csrf_meta_tags.
    // The wallet connect JS needs it (no optional chaining on .content).
    document.addEventListener("DOMContentLoaded", () => {
      if (!document.querySelector('meta[name="csrf-token"]')) {
        const meta = document.createElement("meta");
        meta.name = "csrf-token";
        meta.content = "test-csrf-token";
        document.head.appendChild(meta);
      }
    }, { once: true });
  }, { initialSeedByte: seedByte, useWalletStandard: walletStandard });
}

module.exports = { MOCK_PUBKEY_B58, setupPhantomMock };
