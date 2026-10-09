module Entries
  # Move an entry whose payment is unresolved on from what the CHAIN says. THE
  # ONE VERDICT, for both rails: the request that just sent, a retry, the page
  # that polls (#entry_payment_status and #recover_pending_entry), the job and
  # the sweep all end here, and none of them sends anything.
  #
  # The question is "does this entry's ticket exist": the ContestEntry account
  # at the row's pinned wallet and slot, OWNED BY THE VAULT PROGRAM. turf-vault
  # creates it in the same instruction that takes the fee, so it exists if and
  # only if the player paid.
  #
  #   the recorded signature landed, or   → activate the entry (:confirmed), or,
  #   the ticket exists                     when an app gate refuses a paid
  #                                         entry, keep it (:landed)
  #   neither, and the attempt provably   → back to draft with the picks
  #   paid nothing                          (:released)
  #   anything else, or the chain cannot  → :pending; ask again
  #   be read
  #
  # THE ORDER OF THE READS IS PART OF THE RULE. A release that leans on the
  # block height reads the FINALIZED height and then reads the signature's
  # status and the ticket (at `finalized`) AGAIN, after it. So when that height
  # is past the wire's last valid block height, every block the wire could be
  # in was already finalized when the two reads that found nothing were made;
  # a read made before the height carries no such guarantee. What "provably
  # paid nothing" requires is Entry::Payment#payment_release_allowed?, the one
  # place it is written. The height is read only on that path.
  #
  # A DRAFT cart with a pinned slot is asked the same question (#settle_draft):
  # if its ticket exists, an earlier payment landed and the app never learned,
  # and the entry is confirmed instead of being charged, edited or cleared.
  class PaymentSettlement
    Result = Struct.new(:status, :entry, :code, keyword_init: true) do
      def confirmed? = status == :confirmed
      def pending? = status == :pending
      def released? = status == :released
      def landed? = status == :landed
      def idle? = status == :idle
      # The chain could not be read, so nothing is known.
      def unreadable? = pending? && code == :chain_unreadable
    end

    INSTRUCTIONS = %w[enter_contest enter_contest_with_token].freeze
    TICKET_COMMITMENT = "finalized".freeze
    NETWORK_FAULTS = [SystemCallError, IOError, SocketError, OpenSSL::SSL::SSLError, Timeout::Error].freeze
    # Stands in for "past any height" when asking what else the rule needs.
    ANY_HEIGHT = 2**62

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
    rescue Solana::Client::RpcError, *NETWORK_FAULTS => e
      # A read that errors is never a verdict: a 429, a timeout, a refused or
      # reset connection, a DNS or TLS fault.
      Rails.logger.warn("[entry-payment] unreadable entry=#{@entry.id} #{e.class}: #{e.message.to_s[0, 140]}")
      result(:pending, :chain_unreadable)
    end

    private

    def settle
      @entry.reload
      @token = @entry.payment_attempt_token # the attempt this verdict is about
      return result(:confirmed) if @entry.active? || @entry.complete?
      return settle_draft if @entry.payment_pinned_draft?
      return result(:idle) unless @entry.payment_in_flight?

      pda = @entry.payment_entry_pda(@vault)
      status, paid = read_payment(pda)
      return paid if paid
      return result(:landed, @entry.payment_refusal_code) unless @entry.payment_state == "submitted"

      height = nil
      if height_decides?(status)
        # The height, THEN the status and the ticket again (see the class comment).
        height = @vault.client.get_block_height(commitment: "finalized")
        status, paid = read_payment(pda)
        return paid if paid
      end
      return result(:pending) unless @entry.payment_release_allowed?(status: status, finalized_block_height: height, now: @now)
      # ABSENCE IS ASKED TWICE. No ticket at `finalized` is what the rule needs;
      # a ticket already visible at `confirmed` is on its way there, so a signed
      # row is not released over it.
      return result(:pending, :ticket_confirming) if @entry.payment_signature.present? && ticket_arriving?(pda)

      release(status)
    rescue Entry::Payment::IllegalTransition
      result(@entry.reload.payment_in_flight? ? :pending : :idle) # another settlement moved it first
    end

    # The recorded signature's status, and the result when the payment is on
    # chain: the signature landed, or the ticket exists.
    def read_payment(pda)
      status = signature_status(@entry.payment_signature)
      return [status, activate(@entry.payment_signature, pda)] if landed?(status)
      return [status, nil] unless ticket?(pda)

      signature = ticket_signature(pda)
      [status, signature ? activate(signature, pda) : result(:pending, :ticket_unsigned)]
    end

    # Whether the block height is the one thing still to be asked: a signed
    # attempt with no status, for which everything else the rule needs holds.
    def height_decides?(status)
      @entry.payment_signature.present? && status.nil? &&
        @entry.payment_release_allowed?(status: nil, finalized_block_height: ANY_HEIGHT, now: @now)
    end

    # Why it paid nothing: the hint the sending request left, else what the
    # chain itself showed.
    # An unsigned release asserts the row is still unsigned in its UPDATE: a
    # signature recorded since the read means a wire may be out.
    def release(status)
      code = @entry.payment_refusal_code.presence || release_code(status)
      if @entry.payment_signature.blank?
        return result(:pending) unless @entry.release_unsent_attempt!(@entry.payment_attempt_token, code)
      else
        @entry.release_payment!(code)
      end
      close_wire("failed")
      Rails.logger.info("[entry-payment] released entry=#{@entry.id} code=#{code}")
      result(:released, code)
    end

    def release_code(status)
      return :not_sent if @entry.payment_signature.blank?

      status ? :failed_onchain : :expired
    end

    # A pinned draft cart: nothing is in flight, but its ticket address is
    # known. If the ticket is there, an earlier payment landed.
    def settle_draft
      pda = @entry.payment_entry_pda(@vault)
      # `idle` lets a caller move or clear this pin, so absence is asked at
      # both commitments: a ticket seen only at `confirmed` means wait.
      return result(ticket_arriving?(pda) ? :pending : :idle, :ticket_confirming) unless ticket?(pda)
      return result(:idle) if Entry.where.not(id: @entry.id).exists?(onchain_entry_id: pda)

      signature = ticket_signature(pda)
      return result(:pending, :ticket_unsigned) if signature.nil?

      rail = @entry.payment_rail || (@entry.wallet_address == @entry.user.web3_solana_address ? "phantom" : "managed")
      @entry.transition_payment!("submitted", payment_rail: rail, payment_attempt_token: SecureRandom.hex(12),
                                              payment_submitted_at: @entry.payment_submitted_at || @now)
      activate(signature, pda)
    rescue ActiveRecord::RecordNotUnique, Entry::Payment::IllegalTransition
      result(:pending, :other_payment_in_flight)
    end

    def signature_status(signature)
      return nil if signature.blank?

      @vault.client.confirm_transaction(signature)&.dig("value", 0)
    end

    def landed?(status)
      status.present? && status["err"].nil? && %w[confirmed finalized].include?(status["confirmationStatus"])
    end

    # A real ticket: an account the vault program owns, read at `finalized`.
    # Lamports alone do not count, because anyone can send lamports to an address.
    def ticket?(pda)
      value = @vault.client.get_account_info(pda, commitment: TICKET_COMMITMENT)&.dig("value")
      value.present? && value["owner"] == Solana::Config::PROGRAM_ID
    end

    # The ticket is visible at `confirmed`: not yet proof of a payment, and
    # never proof of none.
    def ticket_arriving?(pda)
      @vault.client.get_account_info(pda, commitment: "confirmed")&.dig("value", "owner") == Solana::Config::PROGRAM_ID
    end

    # The transaction that created the ticket: the recorded attempt when it
    # succeeded, else the oldest success on the address (an earlier attempt).
    def ticket_signature(pda)
      recorded = @entry.payment_signature.presence
      status = signature_status(recorded)
      return recorded if status && status["err"].nil?

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

      # A SIGNATURE THAT SUCCEEDED ON CHAIN IS NEVER RELEASED. Every recorded
      # signature is a wire the server stamped and cosigned, so a success means
      # the player paid, whatever the verifier says about the row's pinned
      # address and whether or not a ticket sits there. It is held (`landed`):
      # paid, and either an app gate (lock, capacity, a kicked-off pick) or the
      # verifier refuses to activate it. It never fails and never lapses.
      code = e.respond_to?(:code) ? e.code : :verification_refused
      # A fresh copy: the failed confirm left this one dirty. The move is
      # conditional on the attempt this verdict judged.
      fresh = Entry.find(@entry.id)
      if fresh.payment_state == "submitted" && fresh.payment_attempt_token == @token
        fresh.mark_payment_landed!(code: code, signature: signature)
        capture(e) # once, on the move; a re-check of a landed row is quiet
      end
      @entry.reload
      result(:landed, code)
    rescue ActiveRecord::ActiveRecordError => e
      capture(e)
      result(:pending, :confirm_failed)
    end

    # The player's wallet signed an entry instruction that wrote this ticket.
    def verify_wallet_signed!(signature, pda)
      refusal = nil
      expected_instructions(signature).each do |name|
        return Solana::TxVerifier.verify!(signature: signature, instruction_name: name, signer_pubkey: @entry.wallet_address,
                                          writable_pubkey: pda, client: @vault.client)
      rescue Solana::TxVerifier::NotFound
        raise
      rescue Solana::TxVerifier::VerificationError => e
        refusal = e
      end
      raise refusal
    end

    # Which instruction the wire must carry: the one the server PREPARED for
    # this signature (a token consume must be proved as a consume, never as a
    # transfer); both names only when no prepared wire records it.
    def expected_instructions(signature)
      wire = PendingTransaction.where(target: @entry, tx_type: "enter_contest", tx_signature: signature).order(:id).last
      return INSTRUCTIONS if wire.nil?

      meta = wire.metadata
      meta = JSON.parse(meta) if meta.is_a?(String)
      meta.is_a?(Hash) && meta["entry_token_pda"].present? ? %w[enter_contest_with_token] : %w[enter_contest]
    rescue JSON::ParserError
      INSTRUCTIONS
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
