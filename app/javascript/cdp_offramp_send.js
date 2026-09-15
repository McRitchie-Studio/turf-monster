// Phantom-mode offramp USDC send (docs/CDP_RAMP_INTEGRATION.md §10).
//
// Mirrors the entry/lock_contest sign flow: the SERVER builds the transaction
// (single source of truth for destination resolution + amount — the client
// never dictates either; /cdp/offramp/prepare_send cross-checks the optional
// toAddress/amountBaseUnits expectations against its own row), Phantom signs,
// the SERVER cosigns, the client broadcasts, then the signature is reported
// back to /cdp/offramp/sent where it is verified on-chain before recording.
//
// The cosign hop exists because the HOUSE is the fee payer on this wire
// (phantom-cashout-needs-sol): a player holding USDC and zero SOL could not
// otherwise withdraw at all. Phantom fills its own signature slot, the admin
// slot stays empty until /cdp/offramp/cosign_send fills it, and only then are
// the bytes broadcastable — which is why the Phantom-signed tx is serialized
// with requireAllSignatures:false before it is sent back up.
//
// Usage (offramp return page / cash-out prompt):
//   const sig = await window.buildAndSendOfframpUsdcTransfer({
//     partnerUserRef: ref,            // required — identifies the ramp row
//     toAddress: addr,                // optional cross-check (display value)
//     amountBaseUnits: 19000000,      // optional cross-check (display value)
//     onStatus: (msg) => {...}        // optional progress callback
//   });
// Resolves with the tx signature string; throws Error on any failure
// (caller renders the message — copy must include the 30-minute rule).
export async function buildAndSendOfframpUsdcTransfer(opts) {
  opts = opts || {};
  var partnerUserRef = opts.partnerUserRef;
  if (!partnerUserRef) throw new Error("partnerUserRef is required");
  var onStatus = typeof opts.onStatus === "function" ? opts.onStatus : function () {};

  var provider = window.solana;
  if (!provider || !provider.isPhantom) {
    throw new Error("Phantom wallet is required to send this cash-out.");
  }

  var csrfToken = document.querySelector('meta[name="csrf-token"]');
  csrfToken = csrfToken ? csrfToken.content : null;
  var rpcUrl = document.body.dataset.solanaRpcUrl || "https://api.devnet.solana.com";
  var fetcher = window.authedFetch || window.fetch;
  var postJson = async function (url, body) {
    var resp = await fetcher(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken },
      body: JSON.stringify(body),
    });
    if (!resp) throw new Error("Session expired - please sign in again."); // authedFetch handled 401/429
    var data = await resp.json().catch(function () { return {}; });
    if (!resp.ok) throw new Error(data.error || resp.statusText || "Request failed");
    return data;
  };

  // 1. Server resolves the Coinbase destination + builds the unsigned tx.
  onStatus("Preparing the transfer...");
  var prep = await postJson("/cdp/offramp/prepare_send", {
    partner_user_ref: partnerUserRef,
    to_address: opts.toAddress,
    amount_base_units: opts.amountBaseUnits,
  });

  // 2. Phantom signs — it must hold the ramp's source wallet.
  var resp = await provider.connect();
  var connected = resp.publicKey.toBase58();
  if (prep.wallet_address && connected !== prep.wallet_address) {
    throw new Error(
      "Wrong wallet connected. Switch Phantom to " + prep.wallet_address.substring(0, 8) + "... and retry."
    );
  }

  onStatus("Approve the transfer in your wallet...");
  var txBytes = Uint8Array.from(atob(prep.serialized_tx), function (c) { return c.charCodeAt(0); });
  var tx = solanaWeb3.Transaction.from(txBytes);
  if (window.confirmSolanaNetworkIntent) {
    await window.confirmSolanaNetworkIntent({ action: "Cash out USDC" });
  }
  var signed = await provider.signTransaction(tx);

  // 3. Server cosigns the admin (fee payer) slot. requireAllSignatures:false —
  //    the admin slot is still empty here, so a default serialize() would throw
  //    rather than hand us the bytes to send up. The server re-derives the
  //    destination and amount itself and refuses any wire that is not the
  //    cash-out it prepared, so this round trip cannot widen what gets signed.
  onStatus("Confirming the transfer...");
  var wireToCosign = btoa(
    String.fromCharCode.apply(null, signed.serialize({ requireAllSignatures: false }))
  );
  var cosigned = await postJson("/cdp/offramp/cosign_send", {
    partner_user_ref: partnerUserRef,
    signed_tx: wireToCosign,
  });

  // 4. Broadcast + confirm (same HTTP-poll confirmation as lock_contest).
  onStatus("Sending USDC to Coinbase...");
  var fullySigned = Uint8Array.from(atob(cosigned.signed_tx), function (c) {
    return c.charCodeAt(0);
  });
  var connection = new solanaWeb3.Connection(rpcUrl, "confirmed");
  var signature = await connection.sendRawTransaction(fullySigned, {
    skipPreflight: true,
    maxRetries: 3,
  });

  onStatus("Waiting for Solana confirmation...");
  await window.pollConfirmation(rpcUrl, signature);

  // 5. Report back — server verifies the signature on-chain, records it on
  //    the ramp row, and nudges the CDP status poll to reconcile.
  onStatus("Recording your send...");
  await postJson("/cdp/offramp/sent", {
    partner_user_ref: partnerUserRef,
    tx_signature: signature,
  });

  return signature;
}

window.buildAndSendOfframpUsdcTransfer = buildAndSendOfframpUsdcTransfer;
