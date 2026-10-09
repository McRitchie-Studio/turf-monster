class Contest
  # THE CONTEST'S SETTLEMENT LIFECYCLE. The database holds the proposal and a
  # pointer; the chain holds the money (docs/CHAIN_IS_THE_RECORD.md).
  #
  #   open                entries, then games. Contest#grade! is the way out.
  #   settlement_pending  graded: every entry has its final rank and its prize.
  #                       That is a PROPOSAL. A settle_contest transaction is
  #                       queued for cosigning (PendingTransaction) and nothing
  #                       has been paid.
  #   settled             the settle transaction is confirmed on chain, or the
  #                       contest owed nothing on chain when it was graded (an
  #                       off-chain contest, or one where no entry won a prize).
  #
  # ONE DOOR TO SETTLED. settlement_pending becomes settled only through
  # #mark_settled!, which takes the confirmed signature; any other write of
  # that move is refused by a validation. The two callers have each read the
  # chain first: Admin::PendingTransactionsController (the operator's cosign)
  # and Contests::SettlementReconciler (the sweep).
  #
  # A SETTLE THAT DOES NOT PAY CHANGES NOTHING HERE. A transaction that lands
  # and fails, or one that can no longer land, leaves the contest
  # settlement_pending with the reason in `settlement_error`, and returns its
  # PendingTransaction to `pending` so the operator can rebuild and cosign it.
  # The ranks and prizes are fixed at grade: #grade! refuses a second run.
  #
  # TWO QUESTIONS, TWO PREDICATES. "Are the results final?" is #graded?. "Has
  # the money moved?" is #settled?. A reader that shows ranks asks the first; a
  # reader that says paid, or closes the on-chain account, asks the second.
  module Settlement
    extend ActiveSupport::Concern

    GRADED_STATUSES = %w[settlement_pending settled].freeze
    # What a player can be shown: everything but a `pending` contest, whose
    # creation is not verified on chain.
    LISTED_STATUSES = %w[open settlement_pending settled].freeze
    SETTLE_TX_TYPE = "settle_contest".freeze
    ERROR_LIMIT = 500

    SETTLEMENT_PENDING_GRADE_MESSAGE =
      "Cannot grade: this contest is already graded and its settlement is pending. " \
      "Its ranks and prizes are fixed; cosign or rebuild the settle transaction to pay them.".freeze

    # The move to settled was asked for without a confirmed signature.
    class NotConfirmed < StandardError; end

    included do
      scope :graded, -> { where(status: GRADED_STATUSES) }
      scope :listed, -> { where(status: LISTED_STATUSES) }

      validate :settled_only_on_confirmation,
               if: -> { will_save_change_to_status?(from: "settlement_pending", to: "settled") }
    end

    # The results are final: ranks and prizes are written and will not change.
    def graded?
      settlement_pending? || settled?
    end

    # The newest settle transaction queued for this contest, whatever its state.
    def settlement_transaction
      PendingTransaction.where(target: self, tx_type: SETTLE_TX_TYPE).order(:id).last
    end

    # THE ONE DOOR TO SETTLED. `signature` is the settle_contest transaction the
    # caller has just read as confirmed on chain. Writes the payout pointers,
    # marks the contest settled and tells the winners, in that order: no winner
    # is told before the contest reads paid.
    #
    # Safe to repeat: a second call for a contest already settled on chain
    # writes nothing and returns false. A `settled` contest whose flag is down
    # is one graded before this lifecycle; it takes the same path.
    def mark_settled!(signature)
      raise NotConfirmed, "A contest is marked settled by its confirmed settle signature" if signature.blank?

      newly_settled = with_lock do
        next false if settled? && onchain_settled?
        raise NotConfirmed, "Contest #{slug} is #{status}: only a graded contest can be marked settled" unless graded?

        record_payout_pointers!(signature)
        @settlement_confirmed = true
        update!(status: "settled", onchain_settled: true, settlement_error: nil)
        true
      ensure
        @settlement_confirmed = false
      end

      announce_settlement
      newly_settled
    end

    # Why the last settle attempt paid nothing. The contest stays
    # settlement_pending; the reason shows beside it until a settle confirms.
    def record_settlement_failure!(reason)
      return false unless settlement_pending?

      update_columns(settlement_error: reason.to_s.truncate(ERROR_LIMIT), updated_at: Time.current)
      true
    end

    # What the operator is told after grading.
    def grade_notice
      return "Contest graded and settled!" unless settlement_pending?

      "Contest graded. Its settlement is pending: nothing is paid until the settle transaction " \
        "is cosigned and confirms on chain (Admin, Pending Transactions)."
    end

    private

    # Whether grading leaves a settle transaction to confirm.
    def settlement_owed?
      onchain? && !onchain_settled?
    end

    def settled_only_on_confirmation
      return if @settlement_confirmed

      errors.add(:status, "becomes settled only when the settle transaction confirms (Contest#mark_settled!)")
    end

    # One ledger row per paid entry, pointing at the signature that paid it. No
    # amount: the chain is the record of what moved. A contest that already
    # carries payout rows keeps them and gets no second set.
    def record_payout_pointers!(signature)
      return if TransactionLog.where(transaction_type: "payout", source: self).exists?

      entries.complete.where("payout_cents > 0").includes(:user).order(:rank, :id).each do |entry|
        TransactionLog.record!(user: entry.user, type: "payout", amount_cents: nil, direction: "credit",
                               source: self, onchain_tx: signature,
                               description: "Payout rank ##{entry.rank} for #{name}")
      end
    end

    # The settlement is a fact by now, so a notification fault is logged and
    # never reported as a failed settle. Contests::WinnerNotifier is idempotent
    # per entry, and EmailDeliveryResendJob re-sends a delivery left unsent.
    def announce_settlement
      notify_winners!
    rescue StandardError => e
      ErrorLog.capture!(e)
    end
  end
end
