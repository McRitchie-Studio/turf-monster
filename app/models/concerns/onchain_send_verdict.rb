# THE FOUR-WAY VERDICT ON A BROADCAST WHOSE ANSWER WE DID NOT GET.
#
# Shared by every model that puts a signed wire on the chain and then has to
# decide, later and from the outside, whether it landed: CdpRampTransaction
# (the Phantom cash-out) and PendingTransaction (the treasury cosign seam).
#
# ── WHY THIS IS A CONCERN AND NOT TWO COPIES ───────────────────────────────
#
# Every caller uses this verdict to decide whether to REWIND a row, and a
# rewind is what lets a second full-amount transfer be built. Getting
# :ambiguous wrong in any copy double-sends real money. CdpRampTransaction
# carried the original and said so in its own comment — "there is one
# implementation, and both callers read it" — so when the treasury seam needed
# the same answer the method moved here rather than being copied.
#
# ── THE TRAP IT EXISTS TO CLOSE ────────────────────────────────────────────
#
# "No row" is NOT "never landed". An absent getSignatureStatuses row also means
# in-flight and not-yet-indexed, and it means that for the whole blockhash
# window. Only the AGE OF THE BROADCAST separates the two.
#
# ── THE REQUIREMENTS ON THE INCLUDING MODEL ────────────────────────────────
#
#   * a `broadcast_at` column, stamped immediately BEFORE the wire goes out
#   * a status row fetched with `searchTransactionHistory: true`
#
# Both are load-bearing. Anchoring on anything written AFTER the broadcast
# (confirmed_at, updated_at) can declare a just-broadcast transaction dead
# while it is still perfectly landable — that is how CdpRampTransaction
# double-sent a user's USDC. And a plain `getTransaction` at `confirmed`
# returns nothing for a transaction that is merely unindexed, which reads as
# :never_landed here and is exactly the double-send this guards.
module OnchainSendVerdict
  extend ActiveSupport::Concern

  # A persisted signature still absent from a history-searched
  # getSignatureStatuses this long after the BROADCAST ATTEMPT can never land.
  # This is the number that decides whether a rewind is verified-dead or a
  # double-send.
  BLOCKHASH_LAPSE = 5.minutes

  # Given this row's getSignatureStatuses value (`confirm_transaction(sig).dig("value", 0)`):
  #
  #   :landed        — confirmed/finalized with no err. The money MOVED.
  #   :failed        — an on-chain err. Definitive: the funds did NOT move.
  #   :never_landed  — absent from a HISTORY-SEARCHED lookup, long past the
  #                    blockhash window. Verified-dead, not merely unseen.
  #   :ambiguous     — anything else, and the ONLY safe answer to most of them.
  def send_verdict(status, now: Time.current)
    if status && status["err"].nil? && %w[confirmed finalized].include?(status["confirmationStatus"])
      :landed
    elsif status && status["err"]
      :failed
    elsif status.nil? && blockhash_lapsed?(now: now)
      :never_landed
    else
      :ambiguous
    end
  end

  # No anchor is AMBIGUOUS, never verified-dead. A row broadcast before
  # `broadcast_at` existed, or one whose claim did not stamp it, must never be
  # rewound on the strength of a missing status.
  def blockhash_lapsed?(now: Time.current)
    broadcast_at.present? && now > broadcast_at + BLOCKHASH_LAPSE
  end
end
