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

// Read the extra-cosigner choices that sit beside a Co-sign button.
//
// Scoped to the button's own controls container, NOT the document: this page
// renders one row per pending transaction, and a document-wide query would
// hand every row the first row's wallet. That failure is silent right up to
// the point the chain reports DuplicateSigner or Unauthorized on a payout.
window.collectExtraCosigners = function(buttonEl) {
  var scope = buttonEl && buttonEl.closest ? buttonEl.closest('[data-cosign-controls]') : null;
  if (!scope) return [];

  return Array.prototype.map.call(
    scope.querySelectorAll('[data-extra-cosigner]'),
    function(el) { return el.value; }
  ).filter(function(v) { return !!v; });
};

// KEEP THE ROSTER HONEST WHEN HE CHANGES HIS MIND.
//
// The roster is rendered server-side with whichever wallet the select names at
// page load. If the operator picks a different one and the roster still shows
// the old address, the page is lying about which wallet is about to be asked
// for — and he is switching Phantom accounts by reading exactly that row. So
// the row is repointed on `change`, scoped to the row's own controls container.
document.addEventListener('change', function(evt) {
  var select = evt.target;
  if (!select || !select.matches || !select.matches('[data-extra-cosigner]')) return;

  var scope = select.closest('[data-cosign-controls]');
  if (!scope) return;

  // The LAST roster row is the extra slot — the server row and the named
  // cosigner are fixed, and the extras follow them in reserved order.
  var rows = scope.querySelectorAll('[data-signer-row]');
  var row = rows[rows.length - 1];
  if (!row) return;

  row.setAttribute('data-signer-row', select.value);
  var addressEl = row.querySelector('[data-signer-address]');
  if (addressEl) {
    var key = String(select.value || '');
    addressEl.textContent = key.length > 12 ? key.slice(0, 4) + '\u2026' + key.slice(-4) : key;
  }
});

// `opts` is OPTIONAL and every existing caller omits it, so the treasury flow
// is byte-identical to what shipped. It exists for ONE reason: /admin/authorities
// runs the same ceremony against different endpoints, and a forked copy of this
// 260-line function would be a second place for the wallet-guard suppression,
// the roster painting and the "never guess blockhash expired" error handling to
// drift. Two endpoints and one signer-queue source are the whole difference.
//
//   opts.rebuildUrl    — where to mint fresh bytes at click time
//   opts.broadcastUrl  — where to POST the signed wire
//   opts.successNoun   — what landed, in the surface's own words
//   opts.backLabel     — the success CTA's label
window.cosignTransaction = async function(slug, txTypeLabel, extraCosigners, buttonEl, opts) {
  var label = (txTypeLabel && String(txTypeLabel).trim()) || 'Transaction';
  opts = opts || {};
  var rebuildUrl = opts.rebuildUrl || ('/admin/pending_transactions/' + slug + '/rebuild');
  var broadcastUrl = opts.broadcastUrl || ('/admin/pending_transactions/' + slug + '/broadcast');

  // The wallets whose remaining-account slots this build must reserve. Chosen
  // on the page BEFORE the clock starts, because the slots are part of the
  // message and cannot be added once the first wallet has signed.
  var chosenExtras = (extraCosigners || []).filter(function(a) { return !!a; });
  var modal = window.Alpine && Alpine.store('solanaModal');
  var walletStore = window.Alpine && Alpine.store && Alpine.store('wallet');

  // A wallet address the operator can match against what Phantom shows him.
  // Phantom's own account list abbreviates the same way, so the head and tail
  // are what he is actually reading off the screen; a full 44-character key in
  // a modal is a string nobody compares character by character.
  var shortKey = function(pubkey) {
    var key = String(pubkey || '');
    return key.length > 12 ? key.slice(0, 4) + '\u2026' + key.slice(-4) : key;
  };

  // THE ROSTER — "what's done and what's next", kept true while he works.
  //
  // Three signatures collected across Phantom account switches is more state
  // than anyone should hold in their head between extension dialogs. Each row
  // carries data-signer-row="<address>"; the indicator inside it takes one of
  // five states: pending | connected | signing | signed | failed.
  //
  // Scoped to the clicked button's own controls container for the same reason
  // collectExtraCosigners is: this page renders one row PER pending
  // transaction, and a document-wide write would paint every queued
  // transaction's roster with this one's progress.
  // PASSED IN, NOT SNIFFED. `window.event` would have saved a parameter and is
  // deprecated, absent under a real listener, and wrong whenever anything else
  // is mid-dispatch — a roster that paints the wrong row is worse than one that
  // does not paint at all.
  var rosterScope = (buttonEl && buttonEl.closest)
    ? buttonEl.closest('[data-cosign-controls]')
    : null;

  var paintSigner = function(pubkey, state) {
    if (!rosterScope) return;
    var row = rosterScope.querySelector('[data-signer-row="' + pubkey + '"]');
    if (!row) return;
    var indicator = row.querySelector('[data-signer-state]');
    if (indicator) indicator.dataset.state = state;
  };

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
    var rebuildResp = await fetch(rebuildUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-Token': csrfToken
      },
      body: JSON.stringify({ extra_cosigners: chosenExtras })
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

    // 2. Phantom fills EVERY slot the admin key did not. The server signs as
    //    admin at build time; the named cosigner slot and each extra
    //    remaining-account slot are collected here, in the order the server
    //    reserved them — turf-vault reads those accounts positionally.
    //
    //    The signing plan comes back WITH the bytes (rebuilt.cosigner_address
    //    + rebuilt.extra_cosigners) rather than being read off the page, so
    //    the browser can only ever collect against the slots this very build
    //    reserved. A page rendered before a threshold changed cannot put the
    //    wrong wallet in a slot.
    //    `signer_queue` WINS WHEN THE SERVER SENDS ONE. The two-part
    //    cosigner+extras construction below assumes account 0 was filled by the
    //    server at build time, which is true of every treasury action and FALSE
    //    of an eviction that removes the server's own vault key: that one is
    //    built unsigned with one of the operator's wallets in account 0, so the
    //    lead has to be collected too. The server knows which shape it built;
    //    the browser must not re-derive it.
    var signerQueue = (rebuilt.signer_queue && rebuilt.signer_queue.length)
      ? rebuilt.signer_queue.slice()
      : [rebuilt.cosigner_address || provider.publicKey.toBase58()]
          .concat(rebuilt.extra_cosigners || []);

    var signedB64;
    try {
      if (window.confirmSolanaNetworkIntent) {
        await window.confirmSolanaNetworkIntent({ action: 'Cosign transaction' });
      }

      // The server's own slot was filled when the transaction was built, so it
      // is DONE before the operator touches anything. Painting it as done up
      // front is what makes the roster's count agree with the threshold —
      // otherwise three-signatures-required shows two rows to act on and the
      // arithmetic looks wrong.
      paintSigner(rebuilt.fee_payer_address, 'signed');
      signerQueue.forEach(function(pubkey) { paintSigner(pubkey, 'pending'); });
      if (provider.publicKey) paintSigner(provider.publicKey.toBase58(), 'connected');

      // TELL THE WALLET WATCHER THIS SWITCHING IS ON PURPOSE.
      //
      // Collecting three signatures REQUIRES the operator to change Phantom
      // accounts, and the watcher reads any switch away from the session's
      // address as an identity change — it opens the `wallet-changed` card with
      // dismissible:false, which would cover this flow, refuse to close, and
      // strand a half-collected treasury transaction. Declaring the exact
      // wallets keeps the guard armed for every OTHER address.
      if (walletStore && walletStore.expectSwitchesTo) {
        walletStore.expectSwitchesTo(signerQueue);
      }

      signedB64 = await window.cosignSignatures.collect(provider, serializedTx, signerQueue, {
        onPrompt: function(pubkey, index, total) {
          paintSigner(pubkey, 'signing');
          if (!modal) return;
          var step = total > 1 ? ' (' + (index + 1) + ' of ' + total + ')' : '';
          modal.show('Co-signing ' + label + step,
                     'Approve the transaction in Phantom as ' + shortKey(pubkey) + '…');
        },
        // A SWITCH IS AN INSTRUCTION, NOT AN ERROR. Phantom exposes one
        // account at a time and only the operator can change it, so the only
        // thing this flow can do is say plainly which wallet it needs next.
        onWaiting: function(pubkey) {
          if (!modal) return;
          modal.show('Switch Phantom Account',
                     'Open Phantom and select ' + shortKey(pubkey) + ', then approve. ' +
                     'This transaction needs ' + signerQueue.length + ' wallet signatures.');
        },
        onSigned: function(pubkey) { paintSigner(pubkey, 'signed'); },
        onFailed: function(pubkey) { paintSigner(pubkey, 'failed'); }
      });
    } catch (rejectErr) {
      var rejMsg = rejectErr && rejectErr.message ? rejectErr.message : String(rejectErr);
      if (/user rejected/i.test(rejMsg) || /user declined/i.test(rejMsg) || (rejectErr && rejectErr.code === 4001)) {
        fail(rejMsg, { title: 'Cancelled', body: 'You declined the co-signature in Phantom.' });
        return;
      }
      throw rejectErr;
    } finally {
      // EVERY exit path, including the early `return` above and a thrown
      // rejection. A suppression that outlives its flow disarms the wallet
      // guard for the rest of the page — silently, and for every wallet.
      if (walletStore && walletStore.clearExpectedSwitches) {
        walletStore.clearExpectedSwitches();
      }
    }

    // 3. Hand the signed wire to the server. It simulates first (so a program
    //    error is reported as itself and never reaches the chain), broadcasts
    //    over the credentialed RPC, then runs the OPSEC-010/011 verification
    //    and flips the DB state — all in one round trip.
    if (modal) modal.show('Confirming Onchain', 'Broadcasting from the server…');

    var resp = await fetch(broadcastUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-Token': csrfToken
      },
      body: JSON.stringify({
        signed_tx: signedB64,
        // The SERVER's plan, echoed back — not `provider.publicKey`, which by
        // now holds whichever account the operator switched to LAST and would
        // record the wrong wallet as the named cosigner.
        cosigner_address: signerQueue[0],
        extra_cosigners: signerQueue.slice(1),
        // The WHOLE queue, unsplit. The pair above cannot express an
        // operator-led build (account 0 is a signer to collect, not a spent
        // one), so the eviction endpoint reads this and refuses a set that is
        // not the one whose slots it reserved. Additive: the treasury endpoint
        // ignores it and keeps reading the pair.
        signer_queue: signerQueue
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
        // Generic success variant — an admin action, so NO entry confetti. The
        // CTA reloads so the now-confirmed row refreshes to its green badge (the
        // generic card's CTA is a plain link with no auto-redirect drain). We
        // also reload on a bare Dismiss / backdrop close via onClose, but the
        // CTA is the reliable path across every dismiss route.
        //
        // THE COPY IS NO LONGER TREASURY-ONLY. This engine had exactly one
        // caller for its whole life, so "the treasury transaction" and "Back to
        // Treasury" were accurate by construction. /admin/authorities is the
        // first caller that is not the treasury, and telling an operator he has
        // just completed a TREASURY transaction after he evicted a compromised
        // vault signer is wrong in the one place it most matters — the receipt
        // he reads to confirm the eviction landed.
        //
        // Derived from the page, not from a second flag: the CTA goes back where
        // he already is, so its name is that page's name. `opts.successNoun` is
        // the surface's own word for what landed; the treasury caller passes
        // nothing and keeps its exact sentence.
        var noun = opts.successNoun || 'treasury transaction';
        var backLabel = opts.backLabel || 'Back to Treasury';
        modal.success(signature, 'Transaction confirmed on-chain.', {
          variant: 'generic',
          title: label + ' Confirmed',
          subtitle: 'The ' + noun + ' landed on-chain and has been recorded.',
          ctaLabel: backLabel,
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
