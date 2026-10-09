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
  #   landed, no error    → verify it is this contest's settle and that the
  #                         contest account reads Settled, then the contest is
  #                         settled (Contest::Settlement#mark_settled!) and
  #                         the row confirmed                        (:settled)
  #   anything else that   → nothing changes; ask again              (:pending)
  #   can still land
  #   the status cannot be → nothing changes; ask again           (:unreadable)
  #   read
  #
  # A signature that failed, or has no status past its blockhash window, is
  # NOT proof that nothing was paid. The contest account, read at `finalized`
  # (PendingTransaction#settle_rewind_hold), decides:
  #
  #   Open or Locked       → nothing was paid. The row returns to `pending`
  #                          for a rebuild; the reason is written on the
  #                          contest, which stays settlement_pending
  #                                                       (:failed, :expired)
  #   Settled, no status   → the contest is settled under the row's signature
  #                          and the row confirmed                   (:settled)
  #   Settled, failed      → another transaction paid. The row keeps its
  #   signature              signature; a person looks            (:unverified)
  #   absent, any other    → nothing changes; ask again                (:held)
  #   status, or the read
  #   fails
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

      case @tx.reconcile_broadcast!(status, now: @now, vault: @vault)
      when :landed then settle(signature)
      when :failed then result(:failed, @contest.reload.settlement_error)
      when :never_landed then result(:expired, @contest.reload.settlement_error)
      when :contest_settled then settle_from_account(signature, status)
      when :rewind_held then result(:held, "the contest account does not read Open, Locked or Settled at finalized")
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
      verify!(signature)
      return result(:pending, "landed; the contest account does not read Settled yet") unless chain_reads_settled?

      record_settled(signature)
    end

    # The contest account reads Settled at `finalized`, so its winners are
    # paid, though the signature's status does not read landed.
    #
    # No status: the row's signature is recorded as the settle. It is verified
    # when the transaction is readable; a readable transaction that is not
    # this contest's settle raises and is left for a person. An unreadable one
    # is recorded unverified, and logged.
    #
    # A failed status: this wire paid nothing, so another transaction settled
    # the contest. Nothing is recorded under this signature.
    def settle_from_account(signature, status)
      return settled_elsewhere(signature, status) if status

      begin
        verify!(signature)
      rescue Solana::TxVerifier::NotFound
        Rails.logger.warn("[settlement] #{@tx.slug} contest reads Settled at finalized; sig=#{signature} is not readable, recorded unverified")
      end
      record_settled(signature)
    end

    def verify!(signature)
      Solana::TxVerifier.verify!(signature: signature, instruction_name: INSTRUCTION,
                                 writable_pubkey: contest_account, client: @vault.client)
    end

    def record_settled(signature)
      cosigners = chain_cosigners(signature)
      Rails.logger.warn("[settlement] #{@tx.slug} landed with no configured vault cosigner among its signers") if cosigners.empty?

      @contest.mark_settled!(signature)
      @tx.update!(status: "confirmed", cosigner_address: cosigners.first, cosigner_addresses: cosigners)
      Rails.logger.info("[settlement] settled #{@contest.slug} sig=#{signature}")
      result(:settled)
    end

    def settled_elsewhere(signature, status)
      reason = "The contest account reads Settled on chain, so its winners are paid, but the settle transaction " \
               "#{signature} failed on chain (#{status['err'].inspect.truncate(120)}). It is not re-sent and the " \
               "contest is not marked settled; find the transaction that settled it and confirm it by hand."
      @contest.record_settlement_failure!(reason)
      result(:unverified, reason)
    end

    def unverified(error)
      reason = "The settle transaction #{@tx.tx_signature} landed but could not be verified as this " \
               "contest's settlement (#{error.message.to_s.truncate(160)}). It is not re-sent and the " \
               "contest is not marked settled; read the transaction and confirm it by hand."
      @contest.record_settlement_failure!(reason)
      ErrorLog.capture!(error)
      result(:unverified, reason)
    end

    # The contest account's own status, the second read behind the signature.
    # An absent account was closed after it settled or was cancelled, which
    # this read cannot tell apart; the verified settle above already can.
    def chain_reads_settled?
      onchain = @vault.read_contest(@contest.slug, commitment: "confirmed")
      onchain.nil? || onchain[:status] == "Settled"
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
