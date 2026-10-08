module Entries
  # Move an entry whose payment is unresolved on from what the CHAIN says. One
  # verdict for both rails, for the request that just sent, the page that polls,
  # the retry that was refused, and the sweep.
  #
  # The question is never "did my transaction succeed" (an error string, a
  # timeout and a lost response all fail to answer it). It is "does this entry's
  # ticket exist": the ContestEntry account at the row's pinned wallet and slot.
  # turf-vault creates that account in the same instruction that takes the fee,
  # so it exists if and only if the player paid.
  #
  #   ticket exists                         → activate the entry (:confirmed), or,
  #                                           when an app gate refuses a paid
  #                                           entry, keep it (:landed)
  #   no ticket, and the attempt can no     → back to draft with the picks
  #   longer land                             (:released)
  #   no ticket yet, or the chain cannot    → :pending; ask again
  #   be read
  #
  # "Can no longer land" is the wire's last valid block height against the
  # FINALIZED height, read before the ticket, so every block the transaction
  # could be in is settled by the time the ticket is looked for.
  class PaymentSettlement
    Result = Struct.new(:status, :entry, :code, keyword_init: true) do
      def confirmed? = status == :confirmed
      def pending? = status == :pending
      def released? = status == :released
      def landed? = status == :landed
    end

    INSTRUCTIONS = %w[enter_contest enter_contest_with_token].freeze

    def self.call(entry, vault: Solana::Vault.new, now: Time.current)
      new(entry, vault: vault, now: now).call
    end

    def initialize(entry, vault:, now:)
      @entry = entry
      @vault = vault
      @now = now
    end

    def call
      Solana::Deadline.long_budget(:entry_payment_settlement) { settle }
    rescue Solana::Client::RpcError => e
      Rails.logger.warn("[entry-payment] unreadable entry=#{@entry.id} #{e.class}: #{e.message.to_s[0, 140]}")
      result(:pending, :chain_unreadable)
    end

    private

    def settle
      @entry.reload
      return result(:confirmed) if @entry.active? || @entry.complete?
      return result(:idle) unless @entry.payment_in_flight?

      pda = @entry.payment_entry_pda(@vault)
      height = @vault.client.get_block_height(commitment: "finalized") if @entry.payment_state == "submitted"

      if ticket?(pda)
        signature = ticket_signature(pda)
        return result(:pending, :ticket_unsigned) if signature.nil?

        return activate(signature, pda)
      end
      return result(:landed, @entry.payment_refusal_code) if @entry.payment_state == "landed"
      return result(:pending) unless @entry.payment_attempt_lapsed?(finalized_block_height: height, now: @now)

      code = @entry.payment_signature.present? ? :expired : :not_sent
      @entry.release_payment!(code)
      close_wire("failed")
      Rails.logger.info("[entry-payment] released entry=#{@entry.id} code=#{code}")
      result(:released, code)
    rescue Entry::Payment::IllegalTransition
      result(@entry.reload.payment_in_flight? ? :pending : :idle) # another settlement moved it first
    end

    # A real ticket: an account the vault program owns. Lamports alone do not
    # count, because anyone can send lamports to an address.
    def ticket?(pda)
      value = @vault.client.get_account_info(pda)&.dig("value")
      value.present? && value["owner"] == Solana::Config::PROGRAM_ID
    end

    # The transaction that created the ticket: the recorded attempt when it
    # succeeded, else the oldest success on the address (an earlier attempt).
    def ticket_signature(pda)
      recorded = @entry.payment_signature.presence
      if recorded
        status = @vault.client.confirm_transaction(recorded)&.dig("value", 0)
        return recorded if status && status["err"].nil?
      end

      history = @vault.client.send(:call, "getSignaturesForAddress", [pda, { "limit" => 20 }])
      Array(history).reverse.find { |row| row && row["err"].nil? }&.dig("signature")
    end

    def activate(signature, pda)
      # The time gates are judged when the chain took the payment. The program
      # enforces the lock itself, so a ticket that exists was in time; without a
      # readable block time, the moment the attempt was recorded stands in.
      as_of = Solana::TxVerifier.block_time(signature, client: @vault.client) || @entry.payment_submitted_at

      if @entry.payment_rail == "phantom"
        verify_wallet_signed!(signature, pda)
        @entry.confirm_onchain!(tx_signature: signature, entry_pda: pda, as_of: as_of)
      else
        # Durable capture first, so a failed confirm cannot lose the proof.
        @entry.update!(onchain_tx_signature: signature, onchain_entry_id: pda)
        @entry.confirm!(tx_signature: signature, onchain_entry_id: pda, as_of: as_of)
      end
      Rails.logger.info("[entry-payment] confirmed entry=#{@entry.id} tx=#{signature.to_s.first(8)}...")
      close_wire("confirmed")
      announce
      result(:confirmed)
    rescue Entry::Refusal, Solana::TxVerifier::VerificationError => e
      return result(:pending, :not_indexed) if e.is_a?(Solana::TxVerifier::NotFound)

      # Paid, and an app gate (lock, capacity, a kicked-off pick) refuses to
      # activate it. It stays: it never fails and never lapses.
      code = e.respond_to?(:code) ? e.code : :verification_refused
      if @entry.reload.payment_state == "submitted"
        @entry.mark_payment_landed!(code: code, signature: signature)
        capture(e) # once, on the move; a re-check of a landed row is quiet
      end
      result(:landed, code)
    rescue ActiveRecord::ActiveRecordError => e
      capture(e)
      result(:pending, :confirm_failed)
    end

    # The player's wallet signed an entry instruction that wrote this ticket.
    def verify_wallet_signed!(signature, pda)
      refusal = nil
      INSTRUCTIONS.each do |name|
        return Solana::TxVerifier.verify!(signature: signature, instruction_name: name, signer_pubkey: @entry.wallet_address,
                                          writable_pubkey: pda, client: @vault.client)
      rescue Solana::TxVerifier::NotFound
        raise
      rescue Solana::TxVerifier::VerificationError => e
        refusal = e
      end
      raise refusal
    end

    # The Phantom rail's prepared wire follows the entry, so the older ptx
    # checks (ContestsController#player_broadcast_awaiting_verdict) agree.
    def close_wire(status)
      PendingTransaction.where(target: @entry, tx_type: "enter_contest", status: "submitted")
                        .update_all(status: status, updated_at: Time.current)
    end

    def announce
      Message.announce_join!(contest: @entry.contest, user: @entry.user)
    rescue StandardError => e
      Rails.logger.warn("[entry-payment] join announcement failed entry=#{@entry.id} #{e.class}: #{e.message}")
    end

    def capture(error)
      log = ErrorLog.capture!(error)
      log.target = @entry
      log.target_name = @entry.slug
      log.parent = @entry.contest
      log.parent_name = @entry.contest.slug
      log.save!
    rescue StandardError => e
      Rails.logger.error("[entry-payment] could not log #{error.class}: #{e.message}")
    end

    def result(status, code = nil)
      Rails.logger.debug { "[entry-payment] entry=#{@entry.id} -> #{status} #{code}" }
      Result.new(status: status, entry: @entry, code: code&.to_sym)
    end
  end
end
