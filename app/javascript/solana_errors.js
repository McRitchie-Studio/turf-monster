// Solana error parser — maps raw error messages to user-friendly strings
// Extracted from shared/_solana_errors.html.erb

window.parseSolanaError = function(msg) {
  if (!msg) return 'Unknown error';

  // User rejection
  if (/user rejected/i.test(msg) || /user declined/i.test(msg)) {
    return 'Transaction cancelled \u2014 you declined the request in your wallet.';
  }
  // Account deserialization (old layout needs migration)
  if (/0xbbb/i.test(msg) || /\b3003\b/.test(msg) || /AccountDidNotDeserialize/i.test(msg)) {
    return 'Your account needs a one-time upgrade. Please contact support or try again shortly.';
  }
  // Account not initialized
  if (/AccountNotInitialized/i.test(msg) || /0xbc4/i.test(msg)) {
    return "Your onchain account hasn't been set up yet. Please try again.";
  }
  // Invalid account data (missing USDC token account)
  if (/invalid account data/i.test(msg)) {
    return "Transaction failed \u2014 your wallet may not have a USDC token account. Try claiming USDC from the Faucet first.";
  }
  // Insufficient funds
  if (/insufficient funds/i.test(msg) || /\b0x1\b/.test(msg)) {
    return 'Insufficient USDC balance. Top up your wallet via the Faucet.';
  }
  // Blockhash expired
  if (/blockhash not found/i.test(msg) || /block height exceeded/i.test(msg)) {
    return 'Transaction expired. Please try again.';
  }
  // Wallet generic error
  if (msg === 'Unexpected error' || /^unexpected/i.test(msg)) {
    return "Wallet couldn't process the transaction. Check wallet connection and USDC balance.";
  }

  // TurfVault program errors (6000–6012)
  if (/0x1770/.test(msg)) return 'Only admins can perform this action.';
  if (/0x1771/.test(msg)) return 'Invalid token mint.';
  if (/0x1772/.test(msg)) return 'Insufficient onchain balance.';
  if (/0x1773/.test(msg)) return 'Contest is not open for entries.';
  if (/0x1774/.test(msg)) return 'Contest is full.';
  if (/0x1775/.test(msg)) return 'Contest has not been settled yet.';
  if (/0x1776/.test(msg)) return 'Contest is already settled.';
  if (/0x1777/.test(msg)) return 'Duplicate entry.';
  if (/0x1778/.test(msg)) return 'Settlement payouts exceed prize pool.';
  if (/0x1779/.test(msg)) return 'Arithmetic overflow.';
  if (/0x177a/.test(msg)) return 'Invalid payout tiers.';
  if (/0x177b/.test(msg)) return 'Account is already migrated.';
  if (/0x177c/.test(msg)) return 'Invalid account data.';

  // Username validation (6020-6022, turf-vault v0.15.1 set_username.rs).
  // Server-side mirror: Solana::ErrorInterpreter (same messages).
  if (/0x1784/.test(msg) || /UsernameReserved/i.test(msg)) {
    return "Your username can't be registered on-chain — it starts with a reserved word. Change it on your account page (/account) and try again.";
  }
  if (/0x1785/.test(msg) || /UsernameInvalidChars/i.test(msg)) {
    return "Your username contains unsupported characters and can't be registered on-chain. Change it on your account page (/account) and try again.";
  }
  if (/0x1786/.test(msg) || /UsernameTooShort/i.test(msg)) {
    return "Your username is too short to register on-chain (3 characters minimum). Change it on your account page (/account) and try again.";
  }

  // EntryFeeNotSet (6027, turf-vault v0.16 enter_contest) — the contest's
  // entry_fee_by_currency slot for the selected currency_idx is zero (e.g.
  // a USDT entry against a pre-2026-06-10 contest, which only funded the
  // USDC slot). Server-side mirror: Solana::ErrorInterpreter (same message).
  if (/0x178b/.test(msg) || /\b6027\b/.test(msg) || /EntryFeeNotSet/i.test(msg)) {
    return "This contest doesn't accept that currency — try USDC.";
  }

  // Rails / database errors
  if (/duplicate key|UniqueViolation|already exists/i.test(msg)) {
    return 'A record with this name already exists. Try a different name.';
  }
  if (/RecordInvalid/i.test(msg)) {
    var clean = msg.replace(/.*RecordInvalid:\s*/i, '').replace(/Validation failed:\s*/i, '');
    return clean || 'Validation failed. Please check your input.';
  }

  // Catch raw internal errors — show generic message
  if (/PG::|ActiveRecord::|StandardError|RuntimeError|NoMethodError|TypeError/.test(msg)) {
    return 'Something went wrong. Please try again.';
  }

  // Pass through unrecognized messages (likely our own friendly raise messages)
  return msg;
};

// Report a wallet failure the user has ALREADY been shown, so it reaches
// error_logs. Everything on this surface fails client-side — the throw is caught
// by the modal, mapped by parseSolanaError above, and painted into a paragraph —
// so without this call nothing about it exists outside the browser. That is why
// an empty-Phantom user was told to check their USDC balance seven times in one
// production session on 2026-09-06 before an operator noticed by hand.
//
// BOTH HALVES, ALWAYS. `mapped` is what the user read; `raw` is what the wallet
// said. A wrong mapping is invisible in the mapped half alone — the 2026-09-06
// incident WAS a correct mapper meeting a string it had never seen — so the pair
// is the whole diagnostic value of the call.
//
// FIRE AND FORGET, BY CONTRACT. This returns undefined, never a promise: there
// is nothing for a caller to await, so no caller can accidentally block a user
// on it. Three layers keep a reporting fault off the user's screen —
//   * try/catch here, for a synchronous throw (no fetch, no CSRF meta, no JSON);
//   * .catch() on the promise, for a network failure or a 500 (which would
//     otherwise surface as an unhandled rejection);
//   * `typeof` guards at every call site, for a page where this never loaded.
// The response is never read. The server answers 204 whether or not it recorded
// anything, precisely so there is nothing here worth branching on.
//
// PII: the four fields below are the ONLY ones sent, and none of them is a
// credential. A signature, a nonce and the signed SIWS message are absent by
// construction, not by filtering — the caller never has them in hand. The server
// re-checks anyway (Solana::ClientFailureReport), because `raw` is free text a
// WALLET composed and it can quote our nonce back at us.
window.reportWalletFailure = function(stage, provider, raw, mapped) {
  try {
    var meta = document.querySelector('meta[name="csrf-token"]');
    var clip = function(value) {
      return String(value === null || value === undefined ? '' : value).slice(0, 500);
    };
    fetch('/auth/solana/report_failure', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        // Accept, so Rails resolves the request format as JSON rather than
        // falling back to HTML on a bare */* and running the navbar preload.
        'Accept': 'application/json',
        'X-CSRF-Token': (meta && meta.content) || ''
      },
      // The failure a user reacts to by leaving is the one most worth having.
      // keepalive lets the POST outlive the page it was fired from.
      keepalive: true,
      body: JSON.stringify({
        stage: clip(stage),
        provider: clip(provider),
        raw_message: clip(raw),
        mapped_message: clip(mapped)
      })
    }).catch(function() {});
  } catch (_e) {}
};
