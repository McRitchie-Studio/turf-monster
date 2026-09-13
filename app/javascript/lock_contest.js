// Set a contest timestamp (lock or conclusion) via Phantom (web3). Admin-only.
// set_contest_{lock,conclusion}_time are both 1-of-3 vault ops and the admin's
// Phantom wallet is itself a vault signer, so a single Phantom signature
// authorizes either — no co-signer (unlike the 2-of-3 cosign flow). Mirrors the
// entry sign flow; status + errors render through the shared transaction modal
// (Alpine.store('solanaModal')), never alert().
//
// Usage:
//   onclick="lockContestViaPhantom('<slug>', 60)"      → schedule the lock 60s out
//   onclick="concludeContestViaPhantom('<slug>', 60)"  → schedule the conclusion 60s out
//   (inSeconds = 0 → "now".)
async function setContestTimeViaPhantom(slug, inSeconds, opts) {
  const modal = window.Alpine && Alpine.store("solanaModal");
  const fail = (msg, title) => {
    if (modal) {
      if (!modal.visible) modal.show(title || "Failed", "");
      modal.error(msg, title || "Failed");
    } else {
      alert(msg);
    }
  };

  // DESKTOP ONLY, DECLARED THROUGH THE SHARED GATE. This already degraded
  // rather than crashed — it said "Phantom wallet is required." — but that is
  // advice a phone cannot take: no iOS or Android browser can host the
  // extension, so the sentence names a remedy that does not exist on the
  // device reading it. requireDesktop answers with the move that does
  // work (use a desktop) on a phone, and with the ordinary no-wallet remedy on
  // a desktop.
  //
  // THROWN, NOT PAINTED, and that is a limitation worth naming: the buttons
  // that call this live in app/views/contests/** (the contest header, the
  // show page, the turf-totals leaderboard), so there is no single view this
  // flow owns where a notice could be painted ahead of the tap. The admin
  // pages that DO own their views paint via shared/_wallet_desktop_only_notice.
  try {
    window.walletProvider.requireDesktop();
  } catch (gateErr) {
    fail(gateErr.message, window.walletProvider.isMobile() ? "Desktop Required" : "Wallet Required");
    return;
  }

  // Phantom SPECIFICALLY signs: the admin's Phantom key is itself a vault
  // signer and the server verifies it, so the gate above does not replace
  // this check.
  const provider = window.solana;
  if (!provider?.isPhantom) {
    fail("Phantom is required to sign this. Unlock the Phantom extension, then reload.", "Wallet Required");
    return;
  }

  const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
  const rpcUrl = document.body.dataset.solanaRpcUrl || "https://api.devnet.solana.com";
  const prepareUrl = `/contests/${slug}/prepare_${opts.action}_time`;
  const confirmUrl = `/contests/${slug}/confirm_${opts.action}_time`;

  try {
    if (modal) modal.show("Preparing " + opts.noun, "Building the transaction...");

    const resp = await provider.connect();
    const pubkeyB58 = resp.publicKey.toBase58();
    const sessAddr = window.Alpine && Alpine.store("session") && Alpine.store("session").address;
    if (sessAddr && pubkeyB58 !== sessAddr) {
      fail(
        "Wrong wallet connected. Switch to " + sessAddr.substring(0, 8) + "..., or reconnect on the Account page.",
        "Wrong Wallet"
      );
      return;
    }

    // 1. Server builds the TX (bot fee payer + Phantom admin-signer placeholder).
    const prep = await fetch(prepareUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken },
      body: JSON.stringify({ in_seconds: inSeconds }),
    });
    const prepData = await prep.json();
    if (!prep.ok || !prepData.success) {
      fail(prepData.error || prep.statusText || "Failed to prepare");
      return;
    }
    const timestamp = prepData[opts.tsKey];

    // 2. Phantom fills its signature slot.
    if (modal) modal.show("Sign Transaction", "Approve in your wallet...");
    const txBytes = Uint8Array.from(atob(prepData.serialized_tx), (c) => c.charCodeAt(0));
    const tx = solanaWeb3.Transaction.from(txBytes);
    if (window.confirmSolanaNetworkIntent) {
      await window.confirmSolanaNetworkIntent({ action: "Set " + opts.noun.toLowerCase() + " time" });
    }
    const signed = await provider.signTransaction(tx);

    // 3. Broadcast + confirm.
    if (modal) modal.show("Confirming Onchain", "Submitting transaction to Solana...");
    const connection = new solanaWeb3.Connection(rpcUrl, "confirmed");
    const signature = await connection.sendRawTransaction(signed.serialize(), {
      skipPreflight: true,
      maxRetries: 3,
    });

    // HTTP poll getSignatureStatuses instead of connection.confirmTransaction
    // (no WebSocket subscription, no misleading "unknown" timeout).
    if (modal) modal.show("Confirming Onchain", "Waiting for Solana confirmation...");
    await window.pollConfirmation(rpcUrl, signature);

    // 4. Mirror the timestamp server-side — only after the chain confirms.
    if (modal) modal.show("Saving " + opts.noun, "Recording the time...");
    const conf = await fetch(confirmUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken },
      body: JSON.stringify({ tx_signature: signature, [opts.tsKey]: timestamp }),
    });
    const confData = await conf.json();
    if (!conf.ok || !confData.success) {
      fail(confData.error || "Server confirmation failed");
      return;
    }

    // Reload so the live countdown + admin controls reflect the change. (The
    // shared modal's success card is entry-specific, so we don't use it here.)
    if (modal) modal.show(opts.noun + " Set", "Refreshing…");
    window.location.reload();
  } catch (err) {
    console.error(opts.action + " failed:", err);
    fail(err.message || String(err));
  }
}

window.lockContestViaPhantom = function (slug, inSeconds) {
  return setContestTimeViaPhantom(slug, inSeconds, { action: "lock", tsKey: "lock_timestamp", noun: "Lock" });
};

window.concludeContestViaPhantom = function (slug, inSeconds) {
  return setContestTimeViaPhantom(slug, inSeconds, { action: "conclusion", tsKey: "conclusion_timestamp", noun: "Conclusion" });
};
