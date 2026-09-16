# THE ANCHOR THAT MAKES "NEVER LANDED" PROVABLE.
#
# `PendingTransaction#claim_for_broadcast!` stamps this the instant the row is
# claimed — immediately BEFORE the wire goes out, and in the same conditional
# UPDATE that stamps the signature. It is the only thing that separates "this
# transaction is still in flight" from "this transaction can never land": an
# absent getSignatureStatuses row means BOTH, and only the age of the broadcast
# tells them apart (OnchainSendVerdict#send_verdict).
#
# NEVER anchor that verdict on `updated_at`. Any later write bumps it, so a row
# touched after its broadcast would look freshly sent and stay :ambiguous
# forever, while `reload`-free paths could push it the other way. The CDP
# off-ramp learned this as `broadcast_at` vs `confirmed_at` and wrote the
# reasoning down in Cdp::OfframpSendJob — a mis-anchored verdict there
# double-sent a user's USDC.
class AddBroadcastAtToPendingTransactions < ActiveRecord::Migration[8.1]
  def change
    add_column :pending_transactions, :broadcast_at, :datetime
  end
end
