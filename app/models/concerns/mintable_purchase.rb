# Shared mint-audit behavior for fiat token purchases (StripePurchase,
# PaypalPurchase, CoinflowPurchase). The minted tokens themselves live on-chain as
# EntryTokenAccount PDAs in turf-vault; these rows are the chargeback /
# refund forensics trail mapping a charge to its mint TX(s).
module MintablePurchase
  extend ActiveSupport::Concern

  # "refunded" is terminal (H8 sibling, review 2026-06): a refund webhook
  # landing while the mint job is mid-flight must not be clobbered to
  # "minted" — the refund is the authoritative forensics record. Persist the
  # signatures (the on-chain mints DID happen) but keep the refunded status.
  def mark_minted!(signatures)
    reload
    if status == "refunded"
      update!(mint_tx_signatures: signatures.to_json, minted_at: Time.current)
      return
    end
    update!(
      status: "minted",
      mint_tx_signatures: signatures.to_json,
      minted_at: Time.current
    )
  end

  # OPSEC-036: provider refund event — record the refund for forensics.
  def mark_refunded!(reason: nil)
    update!(status: "refunded", refunded_at: Time.current, refund_reason: reason)
  end

  # Prelaunch audit H8 (2026-05-24): the TokenPurchaseJob rescue used to
  # call `update(status: "failed")` unconditionally. If an exception fired
  # AFTER `mark_minted!` (e.g. TransactionLog.record! failing on a DB hiccup
  # post-mint), the audit row would flip from minted → failed even though
  # the on-chain mint succeeded — misleading operators investigating
  # chargebacks. Reload before writing, and refuse to downgrade a minted row.
  def mark_failed_unless_minted!
    reload
    return if status == "minted"
    update!(status: "failed")
  end

  def tx_signatures
    return [] if mint_tx_signatures.blank?
    JSON.parse(mint_tx_signatures)
  rescue JSON::ParserError
    []
  end
end
