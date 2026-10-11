class Entry
  # A LANDED ENTRY'S WAY OUT. A landed row is paid on chain and refused by an
  # app gate (Entry::Payment); its ticket is this row's wallet and slot, so the
  # row itself is the entry. Nothing here sends, refunds or transfers.
  #
  #   the prompt     while the row is unanswered and inside its hold, every
  #                  signed-in page asks the player (shared/_landed_entry_prompt)
  #   re-authorize   the player keeps the entry: the one verdict
  #                  (Entries::PaymentSettlement) activates it with no new payment
  #   decline        the player does not want it: the row stays landed for good
  #                  (#assert_not_declined!) and waits for a person; nothing is
  #                  refunded here
  #   the hold       until the first Sunday 9:00 AM Eastern after the row landed
  #   replace        after the hold (or on a re-authorized row the verdict still
  #                  refuses), the operator runs the same verdict for the player
  #
  # WHAT AN ANSWER LIFTS. Re-authorize and replace each skip two gates in
  # Entry#assert_enterable!, contest capacity and the per-user entry limit,
  # because the chain already counted this ticket against both. Every other
  # gate stands: the contest must be open, the picks valid and unduplicated,
  # the time gates are still judged at the chain's block time, and the
  # signature must verify.
  module LandedHold
    extend ActiveSupport::Concern

    ZONE = "America/New_York".freeze
    # Before the earliest Sunday kickoff the NFL schedules (9:30 AM ET abroad)
    # and four hours before Turf's NFL lock (Contest::LockRule, 1:00 PM ET).
    HOLD_HOUR = 9
    ANSWERS = %w[reauthorized declined].freeze

    class Refused < StandardError; end

    included do
      validates :landed_answer, inclusion: { in: ANSWERS }, allow_nil: true

      # Landed rows the player has not answered, newest first.
      scope :landed_unanswered, -> { where(status: "cart", payment_state: "landed", landed_answer: nil).order(id: :desc) }
    end

    class_methods do
      # The first Sunday HOLD_HOUR in Eastern strictly after `from`. Built from
      # the date and change(hour:), so it is 9:00 wall clock on both DST Sundays.
      def landed_hold_expires_at(from)
        local = from.in_time_zone(ZONE)
        sunday = local.to_date + ((7 - local.wday) % 7)
        expires = sunday.in_time_zone(ZONE).change(hour: HOLD_HOUR)
        expires > from ? expires : (sunday + 7).in_time_zone(ZONE).change(hour: HOLD_HOUR)
      end

      # The rows the prompt asks this player about now.
      def landed_prompts_for(user, now: Time.current)
        return none if user.nil?

        landed_unanswered.where(user_id: user.id).includes(:contest).select { |entry| entry.landed_hold_open?(now: now) }
      end
    end

    def landed?
      cart? && payment_state == "landed"
    end

    # When the row landed. Rows from before payment_landed_at use the attempt.
    def landed_since
      payment_landed_at || payment_submitted_at || updated_at
    end

    def landed_hold_expires_at
      self.class.landed_hold_expires_at(landed_since)
    end

    def landed_hold_open?(now: Time.current)
      landed? && now < landed_hold_expires_at
    end

    # A DECLINE IS FINAL. Entry#assert_enterable! asks this first, so every
    # activation (the verdict, the reconciler, the jobs, the operator) refuses a
    # declined landed row. It reads the row as stored, so a caller that loaded
    # the row before the decline is refused too. Only a landed row is locked
    # (under confirm!'s transaction, against a decline in between): a pre-flight
    # on any other row takes no lock it did not take before.
    def assert_not_declined!
      return unless persisted?

      row = self.class.where(id: id)
      return unless row.pick(:payment_state) == "landed"

      state, answer = row.lock.pick(:payment_state, :landed_answer)
      return unless state == "landed" && answer == "declined"

      raise Entry::Refusal.new(:landed_declined, "The player declined this entry.")
    end

    # Whether the verdict may lift the two counted gates for this row.
    def landed_hold_authorized?
      payment_state == "landed" && landed_answer != "declined" &&
        (landed_answer == "reauthorized" || landed_replaced_at.present?)
    end

    # The player's answer, once, inside the hold. Raises Refused otherwise.
    def answer_landed!(answer, now: Time.current)
      raise ArgumentError, "unknown answer #{answer.inspect}" unless ANSWERS.include?(answer.to_s)

      with_lock do
        raise Refused, "This entry is no longer waiting for your answer." unless landed? && landed_answer.nil?
        raise Refused, "The time to answer has passed. With any question, contact #{Entry::Payment::SUPPORT_EMAIL}." unless landed_hold_open?(now: now)

        update!(landed_answer: answer.to_s, landed_answered_at: now)
      end
      self
    end

    # The operator's go: after the hold, or on a re-authorized row. Never on a
    # declined row. Raises Refused otherwise.
    def authorize_landed_replacement!(operator, now: Time.current)
      with_lock do
        raise Refused, "Entry #{slug} is not a held paid entry." unless landed?
        raise Refused, "The player declined entry #{slug}; a person decides what happens to the payment." if landed_answer == "declined"
        if landed_answer != "reauthorized" && landed_hold_open?(now: now)
          raise Refused, "Entry #{slug} is still in its hold until #{landed_hold_expires_at.in_time_zone(ZONE).strftime('%a %b %-d %-l:%M %p %Z')}."
        end

        update!(landed_replaced_at: now, landed_replaced_by_id: operator&.id)
      end
      self
    end

    # Run the one verdict on an authorized row. It only reads the chain; when
    # the chain cannot be read the settle job asks again.
    def resolve_landed!(vault: Solana::Vault.new)
      settled = Entries::PaymentSettlement.call(self, vault: vault)
      Entries::PaymentSettleJob.perform_later(id) if settled.pending?
      settled
    end
  end
end
