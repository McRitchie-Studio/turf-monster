// Cosign transaction — admin treasury co-signing via Phantom
// Extracted from admin/pending_transactions/index.html.erb
//
// Drives the shared on-chain transaction modal (Alpine.store('solanaModal'))
// so co-signing shows the same "Confirming…" → success/error experience as the
// contest create/entry flows. Uses the GENERIC success variant (admin treasury
// action — no entry-celebration confetti) and stays tx-type agnostic so every
// PendingTransaction type (settle_contest / sweep_operator_revenue / register_
// currency / …) gets the same copy. txTypeLabel is the already-titleized type
// string the view passes through (e.g. "Settle Contest", "Sweep Operator
// Revenue"); it falls back to a generic noun when absent.
//
// THE BROWSER DOES NOT BROADCAST (changed 2026-09-05). It used to call
// connection.sendRawTransaction itself, and on mainnet that failed every time
// for three compounding reasons:
//
//   1. Config.public_rpc_url refuses to hand a credentialed endpoint to a
//      browser, and SOLANA_PUBLIC_RPC_URL was unset — so this page fell back
//      to the free public cluster RPC, which rate-limits browser traffic.
//   2. `new solanaWeb3.Connection(url)` defaults to the `finalized` commitment,
//      so the preflight checked a brand-new blockhash against a bank ~32 slots
//      stale and rejected VALID transactions with BlockhashNotFound.
//   3. serializedTx arrived as a DOM attribute rendered with the PAGE, so its
//      ~60-90s blockhash window had usually elapsed before the first click —
//      and clicking again re-sent the same dead bytes, forever.
//
// Every one surfaced as the same "blockhash may have expired" modal, so a real
// program error looked identical to a throttled RPC. $140 of alpha-contest
// payouts sat unsent from June to September because of it.
//
// Now: fetch a FRESH transaction at click time (so the blockhash window starts
// when the operator clicks, not when the page loaded — this is what removes the
// need to hurry), let Phantom sign it, and POST the signed wire to the server,
// which simulates it, broadcasts it over the credentialed RPC, verifies what
// landed, and reports the program's own error when something is wrong.

window.cosignTransaction = async function(slug, txTypeLabel) {
  var label = (txTypeLabel && String(txTypeLabel).trim()) || 'Transaction';
  var modal = window.Alpine && Alpine.store('solanaModal');

  // Surface failures through the modal when it's available, else fall back to
  // alert() (e.g. modal store not yet registered). A blockhash-expired / send
  // failure tells the operator to hit Rebuild — that's the recovery for the
  // recent-blockhash expiry on this flow.
  var fail = function(rawMsg, opts) {
    opts = opts || {};
    var friendly = (window.parseSolanaError ? window.parseSolanaError(rawMsg) : rawMsg) || 'Unknown error';
    var title = opts.title || (label + ' Failed');
    var body = opts.body || friendly;
    if (modal) {
      if (!modal.visible) modal.show(title, '');
      modal.error(body, title);
    } else {
      alert(body);
    }
  };

  // DESKTOP ONLY, DECLARED THROUGH THE SHARED GATE. Co-signing is a 2-of-3
  // treasury operation; an operator doing it from a phone is not a use case
  // this app supports, and saying "Phantom wallet is required" to a phone —
  // which is what this said before — is a true sentence with no action behind
  // it. requireDesktop gives the desktop-only sentence on a phone and
  // the ordinary no-wallet sentence on a desktop, both through the modal this
  // flow already renders every other failure into.
  //
  // `body` is passed so parseSolanaError never rewrites it: these messages are
  // written for a person, not decoded from a program error.
  try {
    window.walletProvider.requireDesktop();
  } catch (gateErr) {
    fail(gateErr.message, {
      title: window.walletProvider.isMobile() ? 'Desktop Required' : 'Wallet Required',
      body: gateErr.message
    });
    return;
  }

  // Phantom SPECIFICALLY fills the cosigner slot, and the server verifies the
  // address it reports — so the gate above, satisfied by any Solana wallet,
  // does not stand in for this.
  var provider = window.solana;
  if (!provider || !provider.isPhantom) {
    fail('Phantom is required to co-sign transactions.', {
      title: 'Wallet Required',
      body: 'Phantom is required to co-sign transactions. Unlock the Phantom extension, then reload.'
    });
    return;
  }

  // No RPC URL is read here on purpose: the server owns the broadcast now.
  var csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;

  try {
    if (modal) modal.show('Preparing ' + label, 'Building a fresh transaction…');
    await provider.connect();

    // 1. Build the transaction NOW. Its recent blockhash is minted at this
    //    moment, so the operator gets the full ~60-90s window to approve in
    //    Phantom rather than inheriting whatever was left of a window that
    //    opened when the page rendered.
    var rebuildResp = await fetch('/admin/pending_transactions/' + slug + '/rebuild', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-Token': csrfToken
      }
    });

    if (!rebuildResp.ok) {
      var rErr = {};
      try { rErr = await rebuildResp.json(); } catch (e) { /* non-JSON error body */ }
      fail(rErr.error || 'Could not build the transaction.', { title: label + ' Failed' });
      return;
    }

    var rebuilt = await rebuildResp.json();
    var serializedTx = rebuilt.serialized_tx;
    if (!serializedTx) {
      fail('The server returned no transaction to sign.', { title: label + ' Failed' });
      return;
    }

    // 2. Phantom fills the cosigner slot (the admin slot was signed at build).
    var txBytes = Uint8Array.from(atob(serializedTx), function(c) { return c.charCodeAt(0); });
    var tx = solanaWeb3.Transaction.from(txBytes);

    var signed;
    try {
      if (modal) modal.show('Co-signing ' + label, 'Approve the transaction in Phantom…');
      if (window.confirmSolanaNetworkIntent) {
        await window.confirmSolanaNetworkIntent({ action: 'Cosign transaction' });
      }
      signed = await provider.signTransaction(tx);
    } catch (rejectErr) {
      var rejMsg = rejectErr && rejectErr.message ? rejectErr.message : String(rejectErr);
      if (/user rejected/i.test(rejMsg) || /user declined/i.test(rejMsg) || (rejectErr && rejectErr.code === 4001)) {
        fail(rejMsg, { title: 'Cancelled', body: 'You declined the co-signature in Phantom.' });
        return;
      }
      throw rejectErr;
    }

    // 3. Hand the signed wire to the server. It simulates first (so a program
    //    error is reported as itself and never reaches the chain), broadcasts
    //    over the credentialed RPC, then runs the OPSEC-010/011 verification
    //    and flips the DB state — all in one round trip.
    if (modal) modal.show('Confirming Onchain', 'Broadcasting from the server…');

    var wire = signed.serialize();
    var signedB64 = btoa(String.fromCharCode.apply(null, wire));

    var resp = await fetch('/admin/pending_transactions/' + slug + '/broadcast', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-Token': csrfToken
      },
      body: JSON.stringify({
        signed_tx: signedB64,
        cosigner_address: provider.publicKey.toBase58()
      })
    });

    var signature = null;
    if (resp.ok) {
      var okBody = {};
      try { okBody = await resp.json(); } catch (e) { /* tolerate a bodyless 200 */ }
      signature = okBody.tx_signature;
      if (modal) modal.txSignature = signature;
    }

    if (resp.ok) {
      if (modal) {
        // Generic success variant — admin treasury action, so NO entry
        // confetti. The "Back to Treasury" CTA reloads so the now-confirmed
        // row refreshes to its green Confirmed badge (the generic card's CTA
        // is a plain link with no auto-redirect drain). We also reload on a
        // bare Dismiss / backdrop close via onClose, but the CTA is the
        // reliable path across every dismiss route.
        modal.success(signature, 'Transaction confirmed on-chain.', {
          variant: 'generic',
          title: label + ' Confirmed',
          subtitle: 'The treasury transaction landed on-chain and has been recorded.',
          ctaLabel: 'Back to Treasury',
          ctaHref: window.location.pathname
        });
        modal.onClose = function() { window.location.reload(); };
      } else {
        window.location.reload();
      }
    } else {
      // The server's message is the PROGRAM's message (or the RPC's). Show it
      // verbatim — guessing "blockhash expired" at every failure is exactly
      // what hid the real cause for three months.
      var data = {};
      try { data = await resp.json(); } catch (e) { /* non-JSON error body */ }
      fail(data.error || 'The server could not broadcast the transaction.', { title: label + ' Failed' });
    }
  } catch (err) {
    console.error('Co-sign failed:', err);
    fail(err && err.message ? err.message : String(err));
  }
};
