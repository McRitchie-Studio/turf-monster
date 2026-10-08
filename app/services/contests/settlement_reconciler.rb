module Contests
  # Move a settle_contest transaction whose broadcast has no verdict on from
  # what the CHAIN says, and its contest with it. It only reads the chain: it
  # never signs, never sends and never rebuilds, so a repeated run can pay
  # nothing twice.
  #
  # The row is a PendingTransaction left `submitted` with the signature it was
  # broadcast under (PendingTransaction#claim_for_broadcast! stamps it before
  # the send). The verdict is OnchainSendVerdict#send_verdict on that
  # signature's history-searched status:
  #
  #   landed, no error    → verify it is this contest's settle, then the contest
  #                         is settled (Contest::Settlement#mark_settled!) and
  #                         the row confirmed                        (:settled)
  #   landed with an error → nothing was paid. The row returns to `pending` for
  #                          a rebuild; the reason is written on the contest,
  #                          which stays settlement_pending           (:failed)
  #   never landed, and    → the same, with the expiry as the reason (:expired)
  #   its blockhash lapsed
  #   anything else        → nothing changes; ask again              (:pending)
  #   the chain cannot be  → nothing changes; ask again           (:unreadable)
  #   read
  #
  # A transaction that landed but is NOT this contest's settle is left
  # `submitted` with the reason on the contest (:unverified). It is never
  # rewound, because it is on chain, and never settled, because it paid
  # something else; a person looks. The same holds for a verified settle whose
  # contest is not graded here (:ungraded).
  class SettlementReconciler
    Result = Struct.new(:status, :contest, :detail, keyword_init: true)

    INSTRUCTION = Contest::Settlement::SETTLE_TX_TYPE
    NETWORK_FAULTS = Entries::PaymentSettlement::NETWORK_FAULTS

    def self.call(tx, vault: Solana::Vault.new, now: Time.current)
      new(tx, vault: vault, now: now).call
    end

    def initialize(tx, vault:, now:)
      @tx = tx
      @vault = vault
      @now = now
    end

    def call
      @contest = @tx.settlement_contest
      return result(:idle) unless @contest && @tx.awaiting_broadcast_verdict?

      signature = @tx.tx_signature
      # confirm_transaction searches history: a plain status read answers
      # "nothing" for a transaction that is merely unindexed.
      status = @vault.client.confirm_transaction(signature).dig("value", 0)

      case @tx.reconcile_broadcast!(status, now: @now)
      when :landed then settle(signature)
      when :failed then result(:failed, @contest.reload.settlement_error)
      when :never_landed then result(:expired, @contest.reload.settlement_error)
      else result(:pending)
      end
    rescue Solana::TxVerifier::NotFound
      # A lagging node has no record of a signature another node confirmed.
      result(:pending, "landed; the transaction is not readable yet")
    rescue Solana::TxVerifier::VerificationError => e
      unverified(e)
    rescue Contest::Settlement::NotConfirmed => e
      # A verified settle for a contest this app does not hold as graded. The
      # row stays `submitted` and is named by the sweep; a person looks.
      Rails.logger.warn("[settlement] #{@tx.slug} landed for an ungraded contest: #{e.message}")
      result(:ungraded, e.message)
    rescue Solana::Client::RpcError, *NETWORK_FAULTS => e
      # A read that errors is never a verdict.
      Rails.logger.warn("[settlement] unreadable #{@tx.slug} #{e.class}: #{e.message.to_s[0, 140]}")
      result(:unreadable, e.class.name)
    end

    private

    # OPSEC-010/011, the same proof the operator's cosign path gives: the landed
    # transaction carries a settle_contest instruction on the vault program
    # that writes THIS contest's account. Who signed is read off the
    # transaction itself, not claimed by anyone.
    def settle(signature)
      Solana::TxVerifier.verify!(signature: signature, instruction_name: INSTRUCTION,
                                 writable_pubkey: contest_account, client: @vault.client)
      cosigners = chain_cosigners(signature)
      Rails.logger.warn("[settlement] #{@tx.slug} landed with no configured vault cosigner among its signers") if cosigners.empty?

      @contest.mark_settled!(signature)
      @tx.update!(status: "confirmed", cosigner_address: cosigners.first, cosigner_addresses: cosigners)
      Rails.logger.info("[settlement] settled #{@contest.slug} sig=#{signature}")
      result(:settled)
    end

    def unverified(error)
      reason = "The settle transaction #{@tx.tx_signature} landed but could not be verified as this " \
               "contest's settlement (#{error.message.to_s.truncate(160)}). It is not re-sent and the " \
               "contest is not marked settled; read the transaction and confirm it by hand."
      @contest.record_settlement_failure!(reason)
      ErrorLog.capture!(error)
      result(:unverified, reason)
    end

    def contest_account
      @contest.onchain_contest_id.presence ||
        Solana::Keypair.encode_base58(@vault.contest_pda(@contest.slug).first)
    end

    # The vault signers, other than the server's own key, in the landed
    # transaction's signer slots.
    def chain_cosigners(signature)
      message = @vault.client.get_transaction(signature)&.dig("transaction", "message") || {}
      signers = Array(message["accountKeys"]).first(message.dig("header", "numRequiredSignatures").to_i)
      signers & Solana::CosignPlan.eligible_cosigners
    end

    def result(status, detail = nil)
      Result.new(status: status, contest: @contest, detail: detail)
    end
  end
end
