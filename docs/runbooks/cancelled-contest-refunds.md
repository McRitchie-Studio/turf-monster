# Cancelled contest: reconcile and entrant refunds

**Who runs it.** The DB reconcile rides the release (`post_deploy_cmd`) or an
operator. **Every refund is executed by Alex or the Turf Monster operator, never
by an agent alone.** An agent may prepare one; it may not send it.

## What `cancel_contest` does and does not do

`cancel_contest` (2-of-3 multisig) moves the prize pool's full balance back to
the contest **creator** and sets the Contest account's status to `Cancelled`.
It does **not** refund entrants: entry fees never reach the pool (USDC entries go
to operator revenue; token entries consume a voucher bought with fiat). See
`Contest#cancelled?` and `docs/workflows/submit-entry-decision-tree.md` row 7.

The app flips `contests.onchain_cancelled` only when an admin confirms a
`cancel_contest` PendingTransaction. A cancel signed anywhere else leaves the row
reading "not cancelled". That is the drift step 1 repairs.

## Step 1: reconcile the database (no money moves)

```bash
heroku run -a <app> -- bin/rails contests:reconcile_cancelled                 # dry run, every on-chain contest
heroku run -a <app> -- 'SLUGS=<slug> WRITE=1 bin/rails contests:reconcile_cancelled'
```

It reads the chain first and sets `onchain_cancelled` only when the Contest
account reads `Cancelled` **and** the prize-pool token account is empty or closed.
It refuses an unreadable chain, an absent Contest account, and a cancelled
contest whose pool still holds money. In WRITE mode a refusal exits 1. It leaves
`status` alone: a cancelled contest reads "Cancelled" whatever its status.

## Step 2: decide each entrant's refund (a human)

For each paid entry (`entries.onchain_tx_signature` present), establish:

1. **How it was paid.** Read the entry transaction on chain:
   `EnterContestWithToken` means a voucher (find its `MintEntryToken`; source 1 is
   Stripe, 0 is an operator comp, the rest are in `Solana::Vault::ENTRY_TOKEN_SOURCE`).
   `EnterContest` means USDC from the wallet.
2. **Whether they were already made whole.** Look in the wallet's history for an
   operator `MintEntryToken` (source 0) after the cancel, a USDC transfer in, a
   `transaction_logs` credit, or a refund on the provider purchase row
   (`stripe_purchases.refunded_at`) and at the provider itself.
3. **What the Terms owe.** An entry-fee refund is promised for a contest cancelled
   **before** it locks, on request (`pages/terms`).

Then pick one, and record it on the task or the purchase row:

| Paid with | Refund options |
|-----------|----------------|
| Stripe voucher | Refund the charge in the Stripe dashboard (the webhook marks the purchase `refunded`), or mint a replacement voucher (`mint_entry_token`, source 0) |
| USDC | Transfer the fee from operator revenue to the entrant's wallet (a multisig `sweep_operator_revenue`, then a send), or mint a voucher |
| Operator comp | Mint a replacement voucher |

Do not do both: a cash refund on top of a replacement voucher already used pays
the entrant twice.

## Ledger: contests reconciled

| Contest | Cancelled on chain | Reconciled | Entrant refunds |
|---------|-------------------|------------|-----------------|
| 34 `world-cup-week-1-turf-totals` | 2026-06-08 05:38 UTC, 500 USDC back to the creator, pool 0 | `reconcile-cancelled-contest-34` | One paid entrant (user 68, Stripe voucher, $19). An operator voucher (source 0) was minted to them 22 minutes after the cancel and used the same morning on contest 67. The Stripe charge is unrefunded. Decision pending with Alex; the specifics are on the task card, not here, because this repo is public |
