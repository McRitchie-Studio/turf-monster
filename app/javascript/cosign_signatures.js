// Collecting MORE THAN ONE Phantom signature onto one transaction.
//
// ── WHY THIS FILE EXISTS ──────────────────────────────────────────────────
//
// turf-vault v0.26 raised six operator actions to THREE vault signatures. The
// server contributes one (the admin key, patched into its slot after the
// fact), so the browser now has to come back with two rather than one. Three
// signatures have to land on ONE transaction, because `authorize` counts
// distinct signers on a single message — this is not the Squads model, where
// each member approves in a separate transaction against a stored proposal.
//
// ── THE RULE THIS FILE IS BUILT AROUND ────────────────────────────────────
//
// NEVER ASSUME PHANTOM PRESERVES A SIGNATURE IT DID NOT MAKE.
//
// The obvious implementation is to hand the partially-signed Transaction back
// to `signTransaction` for the second wallet and trust that the first
// signature survives. Phantom's sign-only method is documented LEGACY and its
// return shape is not pinned by the docs — turf-vault's own operator console
// (docs/vault-console.html, 3ea4245b) stopped short of a multi-wallet
// collection flow for exactly this reason rather than claim an unproven path.
//
// So this file never depends on it. Each wallet signs a FRESH transaction
// decoded from the same bytes, we extract ONLY that wallet's 64-byte signature,
// and the signatures are merged at the end with `addSignature` — a stable
// web3.js API that writes into the matching slot. The message bytes are
// identical for every signer by construction (they come from one rebuild), so
// every signature stays valid against the merged transaction.
//
// It also fails loudly rather than quietly: a wallet that returns a
// transaction with its own slot still empty is an error here, not a
// transaction that reaches the chain one signature short and comes back as
// 6046 InsufficientSigners with nothing naming which wallet went missing.

(function () {
  "use strict";

  // Phantom exposes ONE account at a time. Switching is a user action inside
  // the extension, so collection is inherently sequential: ask for a wallet,
  // wait for it to become active, sign, ask for the next.
  var ACCOUNT_SWITCH_TIMEOUT_MS = 180000;
  var ACCOUNT_POLL_INTERVAL_MS = 400;

  function b58(key) {
    return key && key.toBase58 ? key.toBase58() : String(key);
  }

  // The 64-byte signature `pubkey` contributed, or null when its slot is still
  // empty. web3.js zero-fills an unsigned slot rather than omitting it, so
  // "present in the array" is not the same as "signed" — an all-zero buffer is
  // exactly what a declined or mis-targeted signature looks like.
  function extractSignature(signedTx, pubkey) {
    if (!signedTx || !signedTx.signatures) return null;

    for (var i = 0; i < signedTx.signatures.length; i++) {
      var pair = signedTx.signatures[i];
      if (!pair || !pair.publicKey) continue;
      if (b58(pair.publicKey) !== pubkey) continue;

      var sig = pair.signature;
      if (!sig || !sig.length) return null;

      for (var j = 0; j < sig.length; j++) {
        if (sig[j] !== 0) return sig;
      }
      return null; // all-zero: the slot was never filled
    }
    return null;
  }

  function decodeTx(serializedTxB64) {
    var bytes = Uint8Array.from(atob(serializedTxB64), function (c) {
      return c.charCodeAt(0);
    });
    return window.solanaWeb3.Transaction.from(bytes);
  }

  // Wait until Phantom's active account is `wanted`.
  //
  // POLLS RATHER THAN RELYING ONLY ON `accountChanged`. Phantom emits that
  // event, but it emits null when the newly selected account has not been
  // connected to this site — in which case the page has to ask for a fresh
  // `connect()` before it can see the key at all. Polling `provider.publicKey`
  // covers both shapes and needs no listener teardown on the error paths.
  function awaitAccount(provider, wanted, onWaiting) {
    if (b58(provider.publicKey) === wanted) return Promise.resolve();

    if (typeof onWaiting === "function") onWaiting(wanted);

    return new Promise(function (resolve, reject) {
      var elapsed = 0;
      var timer = setInterval(function () {
        if (provider.publicKey && b58(provider.publicKey) === wanted) {
          clearInterval(timer);
          resolve();
          return;
        }

        elapsed += ACCOUNT_POLL_INTERVAL_MS;
        if (elapsed >= ACCOUNT_SWITCH_TIMEOUT_MS) {
          clearInterval(timer);
          reject(new Error(
            "Timed out waiting for Phantom to switch to " + wanted + ". Open the Phantom " +
            "extension, select that account, and run the co-signature again."
          ));
        }
      }, ACCOUNT_POLL_INTERVAL_MS);
    });
  }

  // Collect one signature per entry of `signers`, in order, and return a fully
  // merged base64 wire.
  //
  // `signers` is the ORDERED list of pubkeys the browser owes — the named
  // cosigner slot first, then every extra remaining-account slot in the order
  // the server reserved them. Order is load-bearing: turf-vault reads the
  // leading remaining accounts positionally.
  //
  // `hooks` may supply { onPrompt(pubkey, index, total), onWaiting(pubkey),
  // onSigned(pubkey, index, total), onFailed(pubkey) } so the caller owns all
  // the operator-facing copy and the roster it paints.
  //
  // onSigned FIRES PER WALLET, NOT AT THE END. The operator is switching
  // accounts inside an extension between calls, and a roster that only updates
  // when everything is finished tells him nothing while he is working — which
  // is the exact stretch where he has to know what is done and what is next.
  async function collectSignatures(provider, serializedTxB64, signers, hooks) {
    hooks = hooks || {};
    var collected = [];

    for (var i = 0; i < signers.length; i++) {
      var wanted = signers[i];

      await awaitAccount(provider, wanted, hooks.onWaiting);

      if (typeof hooks.onPrompt === "function") {
        hooks.onPrompt(wanted, i, signers.length);
      }

      // A FRESH decode per wallet. Nothing is carried between signers except
      // the extracted 64 bytes, so no assumption is made about what Phantom
      // does with a signature that is already on the transaction it is handed.
      var signed = await provider.signTransaction(decodeTx(serializedTxB64));
      var signature = extractSignature(signed, wanted);

      if (!signature) {
        if (typeof hooks.onFailed === "function") hooks.onFailed(wanted);
        throw new Error(
          "Phantom returned no signature for " + wanted + ". The transaction would have " +
          "reached the chain one signature short. Check that the account selected in " +
          "Phantom is " + wanted + " and try again."
        );
      }

      collected.push({ pubkey: wanted, signature: signature });

      if (typeof hooks.onSigned === "function") {
        hooks.onSigned(wanted, i, signers.length);
      }
    }

    // Merge into ONE transaction. `addSignature` writes into the slot matching
    // the pubkey and throws when that pubkey is not a required signer of this
    // message — which is the check that catches a build whose reserved slots
    // and collected wallets disagree.
    var merged = decodeTx(serializedTxB64);
    collected.forEach(function (entry) {
      merged.addSignature(new window.solanaWeb3.PublicKey(entry.pubkey), entry.signature);
    });

    // requireAllSignatures stays ON. The server's admin slot was filled at
    // build time and every browser slot was just filled here, so a transaction
    // that cannot serialize completely is one we must not broadcast — that is
    // the whole failure this change exists to stop happening on-chain.
    var wire = merged.serialize();
    return btoa(String.fromCharCode.apply(null, wire));
  }

  window.cosignSignatures = {
    collect: collectSignatures,
    extractSignature: extractSignature,
    awaitAccount: awaitAccount
  };
})();
