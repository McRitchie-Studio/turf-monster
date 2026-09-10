module Solana
  # Layer 2 of the entry-blocker design: translates raw on-chain / RPC /
  # Phantom errors into the same { reason, mode, data } blocker shape the
  # JS preflight check (window.eligibilityBlocker) returns. Callers in the
  # entry-flow controllers thread the result into their JSON error response
  # so the client can route through showEligibilityBlockerModal — meaning
  # the user sees identical UX whether the block was caught pre-flight or
  # surfaced from a transaction the chain rejected.
  #
  # Returns:
  #   { message:, blocker: { reason:, mode:, data: } | nil, toast: bool, log: bool }
  #
  # - blocker:nil — error has no actionable retry path (the client falls
  #   back to whatever generic error UI it already had)
  # - toast:true — user intent failure (e.g. they declined the wallet
  #   prompt). Client should show a transient toast, not a modal.
  # - log:true  — operationally interesting; client / server side should
  #   alert (e.g. AccountDidNotDeserialize hints at IDL drift)
  module ErrorInterpreter
    extend self

    def interpret(err, contest: nil, mode: nil)
      msg = err.is_a?(Exception) ? err.message.to_s : err.to_s
      stripped = msg.strip
      mode = mode.to_s

      # Phantom — user declined the signature. Not a real failure.
      if stripped.match?(/user rejected|user declined/i)
        return ok(message: "Transaction canceled.", toast: true)
      end

      # A SELF-CUSTODY ACCOUNT ON A WEB2 SESSION, reaching a path that needs a
      # custodial keypair it does not have. #resolve_web2_entry_funding! raises
      # "Managed wallet missing keypair (cannot sign entry)" for exactly this
      # shape, and until 2026-09-07 that RAISE STRING WAS THE USER-FACING COPY:
      # a player who signed in with Google got a red card reading it, stacked
      # over the web3 step-up card that was already telling them what to do.
      #
      # ContestsController#enter now refuses this before it ever attempts to
      # sign, so this branch is the BACKSTOP rather than the fix — which is
      # precisely why it belongs here. The message is the one thing an
      # interpreter can always promise: whatever else drifts, no raise text
      # reaches a modal. It maps to the same web3_step_up_required blocker the
      # guard returns, so a player who arrives by either route lands on the same
      # card. mode-free on purpose: the account's problem is that it has no
      # managed wallet, which is true whichever session is asking.
      if stripped.match?(/managed wallet missing keypair/i)
        return ok(
          message: "Sign in with your wallet to enter — this account's entries are signed by the wallet itself.",
          blocker: { reason: "web3_step_up_required", mode: "web3", data: {} },
          log: true
        )
      end

      # web2 — managed wallet can't fund the entry by ANY enabled method
      # (no entry token, and USDC entry off or insufficient). Server-side raise
      # from ContestsController#resolve_web2_entry_funding! when the flag is off
      # / token-only. Maps to the no_funding blocker.
      #
      # WHERE THAT BLOCKER SENDS THE PLAYER, because this comment used to name a
      # modal the board does not open. no_funding is answered by ONE client
      # dispatcher, selectionBoard#showFundsNeeded (contests/_turf_totals_board,
      # case 'no_funding'), and it forks once: a web2 session with
      # ENABLE_WEB2_USDC_ENTRY off — the USDC kill-switch audience, who cannot pay
      # an entry with USDC at all — is offered Buy an Entry Token
      # (modals/_buy_entry_token); everyone else gets the Get USDC teaching card
      # (modals/_buy_usdc). Even that fork lands on Get USDC when the server
      # reports no entry-token rail available, so Get USDC is the destination
      # whenever the token rails are dark.
      #
      # It is NOT Top Up Wallet (modals/_wallet_topup), which leads with the CDP
      # onramp and has no legal clearance (operator, 2026-09-06). At head that
      # modal has no entrance at all, and BOTH ways in are closed:
      # selectionBoard#showWalletTopup has no caller, and the Add Funds hub's
      # Back link swaps there only when props.returnModal is 'wallet-topup' — a
      # prop written in exactly one place, modals/_wallet_topup itself, which
      # makes that link a return path from itself rather than a way in. It
      # regains an entrance the moment either condition changes: something calls
      # showWalletTopup, or some other opener passes returnModal: 'wallet-topup'.
      # Re-check both before naming it here again.
      if stripped.match?(/no entry tokens/i)
        return ok(
          message: stripped,
          blocker: { reason: "no_funding", mode: "web2", data: {} }
        )
      end

      # web2 / managed USDC entry underfunded. Two shapes reach here, both
      # meaning "the managed wallet can't cover the USDC entry fee":
      #   1. the #resolve_web2_entry_funding! pre-check raise ("Not enough USDC
      #      …"), which validates the balance BEFORE the irreversible on-chain
      #      enter (the funding-preflight safety net, 2026-06-13); and
      #   2. the raw SPL token-program insufficient-funds error ("custom program
      #      error: 0x1") as a BACKSTOP, on the off chance a $0 entry still
      #      reaches the chain (race / flag flip).
      # Map BOTH to no_funding/web2 so the board routes them through
      # showFundsNeeded — Get USDC (modals/_buy_usdc), or Buy an Entry Token
      # (modals/_buy_entry_token) for the USDC kill-switch audience — instead of
      # leaking the cryptic 0x1 sim error. Top Up Wallet is on neither branch and
      # has no entrance at head; the two conditions that would give it one are
      # spelled out at the no-entry-tokens branch above.
      # web2-scoped: a raw 0x1 means an SPL
      # transfer, which only the managed USDC path performs; web3 underfunding
      # surfaces as Anchor 6002 / 0x1772 (handled below). The 0x1 boundary keeps
      # 0x1772 (6002) from matching here.
      if mode == "web2" && stripped.match?(/not enough usdc|custom program error: 0x1\b/i)
        return ok(
          message: "Not enough USDC to enter. Top up your wallet and try again.",
          blocker: {
            reason: "no_funding",
            mode: "web2",
            data: { neededCents: (contest&.entry_fee_cents.to_i || 0) }
          }
        )
      end

      # InsufficientBalance (6002 / 0x1772). Raised by enter_contest when the
      # wallet's USDC/USDT ATA can't cover the entry fee. mode-aware: a web2 /
      # managed USDC entry that underfunds maps to no_funding/web2, which the
      # board answers through showFundsNeeded — Get USDC (modals/_buy_usdc), or
      # Buy an Entry Token (modals/_buy_entry_token) for the USDC kill-switch
      # audience — NOT the web3 deposit/currency picker, and not Top Up Wallet,
      # which has no entrance at head (both conditions at the no-entry-tokens
      # branch above). web3 (Phantom) keeps the insufficient_balance/web3
      # deposit modal.
      if stripped.match?(/0x1772|\b6002\b|insufficientbalance|insufficient (usdc|onchain|balance|funds)/i)
        if mode == "web2"
          return ok(
            message: "Not enough USDC to enter. Top up your wallet and try again.",
            blocker: {
              reason: "no_funding",
              mode: "web2",
              data: { neededCents: (contest&.entry_fee_cents.to_i || 0) }
            }
          )
        end
        return ok(
          message: "Insufficient balance. Top up your wallet to enter.",
          blocker: {
            reason: "insufficient_balance",
            mode: "web3",
            data: { neededCents: (contest&.entry_fee_cents.to_i || 0) }
          }
        )
      end

      # ContestNotOpen (6003 / 0x1773).
      if stripped.match?(/0x1773|\b6003\b|contest is not open|contestnotopen/i)
        return ok(
          message: "Contest is no longer open.",
          blocker: { reason: "contest_locked", mode: nil, data: {} }
        )
      end

      # ContestFull (6004 / 0x1774).
      if stripped.match?(/0x1774|\b6004\b|contest is full|contestfull/i)
        return ok(
          message: "Contest is full.",
          blocker: { reason: "contest_full", mode: nil, data: {} }
        )
      end

      # AccountDidNotDeserialize (3003 / 0xbbb) on the pinned season means the
      # contest was created against a missing/old Season PDA. The user cannot
      # repair that with a wallet retry; an admin needs to select/create a valid
      # season and create a fresh contest.
      if stripped.match?(/account:\s*season/i) &&
         stripped.match?(/0xbbb|\b3003\b|accountdidnotdeserialize/i)
        return ok(
          message: "This contest's on-chain season is unavailable. Create a new contest after selecting a valid season.",
          log: true
        )
      end

      # AccountDidNotDeserialize (3003 / 0xbbb) — IDL drift. Operational
      # smoke alarm. User can't fix it; we log and show a generic message.
      if stripped.match?(/0xbbb|\b3003\b|accountdidnotdeserialize/i)
        return ok(
          message: "Your account needs a one-time upgrade. Please try again shortly.",
          log: true
        )
      end

      # ── v0.15.1 username codes (6020-6022, audit C2) ─────────────────
      # Raised by create_user_account / set_username when the username fails
      # on-chain validation. The Rails mirror (User::RESERVED_USERNAME_PREFIXES
      # + the username validations) should make these unreachable for normal
      # users — log:true so a hit flags mirror drift.

      # UsernameReserved (6020 / 0x1784) — reserved prefix (admin/turf/mod/…).
      if stripped.match?(/0x1784|\b6020\b|usernamereserved/i)
        return ok(
          message: "Your username can't be registered on-chain — it starts with a reserved word. Change it on your account page (/account) and try again.",
          log: true
        )
      end

      # UsernameInvalidChars (6021 / 0x1785) — bytes outside printable ASCII.
      if stripped.match?(/0x1785|\b6021\b|usernameinvalidchars/i)
        return ok(
          message: "Your username contains unsupported characters and can't be registered on-chain. Change it on your account page (/account) and try again.",
          log: true
        )
      end

      # UsernameTooShort (6022 / 0x1786) — fewer than 3 characters.
      if stripped.match?(/0x1786|\b6022\b|usernametooshort/i)
        return ok(
          message: "Your username is too short to register on-chain (3 characters minimum). Change it on your account page (/account) and try again.",
          log: true
        )
      end

      # ── v0.16 codes (6023-6033) ──────────────────────────────────────

      # InvalidCurrencyIndex (6025 / 0x1789) — currency_idx in enter_contest
      # points at an unused slot. Almost certainly a stale client.
      if stripped.match?(/0x1789|\b6025\b|invalidcurrencyindex/i)
        return ok(
          message: "Currency option is unavailable. Refresh and try again.",
          blocker: { reason: "currency_unavailable", mode: nil, data: {} }
        )
      end

      # CurrencyNotActive (6026 / 0x178a) — currency was active at page load
      # but deactivated before the user submitted.
      if stripped.match?(/0x178a|\b6026\b|currencynotactive/i)
        return ok(
          message: "This currency is no longer accepted. Refresh and try a different one.",
          blocker: { reason: "currency_unavailable", mode: nil, data: {} }
        )
      end

      # EntryFeeNotSet (6027 / 0x178b) — this contest's entry_fee_by_currency
      # has a zero in the selected slot (e.g. a USDT entry against a contest
      # created before slot 1 was funded — see Contest#accepts_usdt).
      # Effectively wrong-currency-picked. JS mirror: solana_errors.js.
      if stripped.match?(/0x178b|\b6027\b|entryfeenotset/i)
        return ok(
          message: "This contest doesn't accept that currency — try USDC.",
          blocker: { reason: "currency_unavailable", mode: nil, data: {} }
        )
      end

      # Operator-only codes — shouldn't reach a user. If they do (bug or
      # admin UI flow), surface a clean message and log so it doesn't
      # vanish into a generic 500.
      if stripped.match?(/0x1787|\b6023\b|currencyalreadyregistered/i)
        return ok(message: "Currency is already registered.", log: true)
      end
      if stripped.match?(/0x1788|\b6024\b|currencyregistryfull/i)
        return ok(message: "Currency registry is full.", log: true)
      end
      if stripped.match?(/0x178c|\b6028\b|contestnotlocked/i)
        return ok(message: "Contest is not locked.", log: true)
      end
      if stripped.match?(/0x178d|\b6029\b|contestnotcancellable/i)
        return ok(message: "Contest cannot be cancelled in its current status.", log: true)
      end
      if stripped.match?(/0x178e|\b6030\b|prizepoolnotempty/i)
        return ok(message: "Prize pool still has tokens — settle or refund first.", log: true)
      end
      if stripped.match?(/0x178f|\b6031\b|emptyrevenueaccount/i)
        return ok(message: "Operator revenue account is empty.", log: true)
      end
      # OPSEC: a sweep aimed at the wrong destination — log loud.
      if stripped.match?(/0x1790|\b6032\b|treasuryauthoritymismatch/i)
        return ok(message: "Treasury ATA does not belong to the pinned treasury authority.", log: true)
      end
      if stripped.match?(/0x1791|\b6033\b|feeandprizebothzero/i)
        return ok(message: "Contest must have at least one entry fee or a non-zero prize pool.", log: true)
      end

      # ── v0.19 codes (6036-6038, audit highs #3/#5/#9) ────────────────
      # Loud — a redirected payout is a fund-safety signal.
      if stripped.match?(/0x1794|\b6036\b|invalidpayoutdestination/i)
        return ok(message: "Settlement payout destination is not the winner's associated token account.", log: true)
      end
      if stripped.match?(/0x1795|\b6037\b|invalidtimestamp/i)
        return ok(message: "Invalid contest time — must be in the future, and the lock must precede the conclusion.", log: true)
      end
      if stripped.match?(/0x1796|\b6038\b|entrytokenseedmismatch/i)
        return ok(message: "Entry token reference hash mismatch — retry the mint.", log: true)
      end

      # Network / RPC flakes — transient, user can just retry.
      if stripped.match?(/blockhash not found|block height exceeded|connection refused|timed out|connection reset/i)
        return ok(message: "Network blip — please try again.", toast: true)
      end

      # Unmapped — pass through, no blocker.
      ok(message: stripped)
    end

    private

    def ok(message:, blocker: nil, toast: false, log: false)
      { message: message, blocker: blocker, toast: toast, log: log }
    end
  end
end
