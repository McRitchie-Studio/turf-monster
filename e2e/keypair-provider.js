/**
 * Keypair provider injection for Playwright devnet smoke tests.
 *
 * Reads a base58-encoded Solana private key from the SOLANA_BOT_KEY env var,
 * decodes it, and injects it as window.__WALLET_KEYPAIR_SECRET before any
 * page scripts run. The wallet_provider.js module auto-detects this and
 * creates a KeypairProvider — no browser extension needed.
 *
 * Usage:
 *   const { setupKeypairProvider, BOT_PUBKEY } = require('./keypair-provider');
 *   await setupKeypairProvider(page);
 *   // Now walletProvider.detect() returns the KeypairProvider
 */

// Server-bot pubkey (derived from SOLANA_BOT_KEY). This is the LEGACY bot
// wallet. The seeded display wallet rotated to 8K81w4e6… on 2026-06-02, and the
// identity is named Xan (renamed from "Alex Bot" on 2026-09-15; it is NOT
// "Alex", who is Mr. McRitchie, and its seeded username is `mcritchie`).
// SOLANA_BOT_KEY is still the private key for THIS (F6f8…) wallet. For the @devnet keypair-login test to
// resolve to the seeded bot again, EITHER seed the bot with F6f8… on devnet OR
// generate a SOLANA_BOT_KEY for 8K81… and update this constant. @devnet only,
// run by hand (e2e/DEVNET_RUNBOOK.md) — excluded from `npm test`.
const BOT_PUBKEY = "F6f8h5yynbnkgWvU5abQx3RJxJpe8EoQmeFBuNKdKzhZ";

/**
 * Decode a base58-encoded string to a Uint8Array.
 * (Runs in Node.js context, not browser.)
 */
function decodeBase58(str) {
  const ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
  let n = BigInt(0);
  for (const c of str) {
    const idx = ALPHABET.indexOf(c);
    if (idx === -1) throw new Error(`Invalid base58 character: ${c}`);
    n = n * 58n + BigInt(idx);
  }

  // Convert BigInt to byte array
  const bytes = [];
  while (n > 0n) {
    bytes.unshift(Number(n & 0xffn));
    n >>= 8n;
  }

  // Preserve leading zeros (base58 '1' = 0x00)
  for (const c of str) {
    if (c !== "1") break;
    bytes.unshift(0);
  }

  return new Uint8Array(bytes);
}

/**
 * Inject the keypair into the page so KeypairProvider picks it up.
 *
 * @param {import('@playwright/test').Page} page
 * @param {string} [base58Key] - Override key (defaults to SOLANA_BOT_KEY env var)
 */
async function setupKeypairProvider(page, base58Key) {
  const key = base58Key || process.env.SOLANA_BOT_KEY;
  if (!key) {
    throw new Error(
      "SOLANA_BOT_KEY env var is required for devnet smoke tests. " +
        "Set it to the e2e bot wallet's (F6f8h5yy…) base58-encoded private key (64 bytes)."
    );
  }

  // Decode in Node.js — pass the raw bytes to the browser
  const secretKeyBytes = Array.from(decodeBase58(key));

  await page.addInitScript((secretBytes) => {
    // Set the secret key for KeypairProvider to detect
    window.__WALLET_KEYPAIR_SECRET = new Uint8Array(secretBytes);

    // Inject dummy CSRF meta tag for test env
    document.addEventListener(
      "DOMContentLoaded",
      () => {
        if (!document.querySelector('meta[name="csrf-token"]')) {
          const meta = document.createElement("meta");
          meta.name = "csrf-token";
          meta.content = "test-csrf-token";
          document.head.appendChild(meta);
        }
      },
      { once: true }
    );
  }, secretKeyBytes);
}

/**
 * Encode bytes as base58 (the inverse of decodeBase58).
 * @param {Uint8Array|number[]} bytes
 * @returns {string}
 */
function encodeBase58(bytes) {
  const ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
  let n = BigInt(0);
  for (const b of bytes) n = (n << 8n) + BigInt(b);
  let out = "";
  while (n > 0n) {
    out = ALPHABET[Number(n % 58n)] + out;
    n /= 58n;
  }
  for (const b of bytes) {
    if (b !== 0) break;
    out = "1" + out;
  }
  return out;
}

/**
 * The public key a base58 64-byte Solana secret key signs as. Deriving it,
 * rather than keeping a pubkey constant beside the secret, means the two can
 * never drift apart when the key rotates.
 *
 * @param {string} base58Key
 * @returns {string} base58 public key
 */
function derivePubkey(base58Key) {
  const secret = decodeBase58(base58Key.trim());
  if (secret.length !== 64) {
    throw new Error(`expected a 64-byte Solana secret key, got ${secret.length} bytes`);
  }
  const nacl = require("tweetnacl");
  return encodeBase58(nacl.sign.keyPair.fromSecretKey(secret).publicKey);
}

module.exports = { setupKeypairProvider, BOT_PUBKEY, decodeBase58, encodeBase58, derivePubkey };
