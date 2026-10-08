class Entry
  # THE ENTRY'S PAYMENT STATE MACHINE. One row, one state, one table of moves;
  # every path that can charge an entry goes through it.
  #
  #   draft      nothing is owed and nothing is in the air. The player may edit,
  #              clear, or submit. A failed or lapsed attempt comes back here
  #              with its picks, and #payment_refusal_code says why.
  #   submitted  a payment was started and its outcome is not known yet.
  #   landed     the chain holds this entry's ticket but the app could not
  #              activate it. It never fails and never lapses (the player paid).
  #   confirmed  the entry is live. Written whenever status becomes active or
  #              complete, so every confirm path lands here without naming it.
  #
  # TWO THINGS MAKE A SECOND CHARGE IMPOSSIBLE, and each covers what the other
  # cannot (turf-vault derives the ticket from contest, WALLET and slot):
  #
  #   * THE PIN. The wallet and slot are fixed before the first send and reused
  #     by every retry (#pin_payment_slot!). The program refuses to create a
  #     ticket that exists, so two transactions for one pin cannot both pay.
  #   * THE IN-FLIGHT KEY. One row per player and contest may be submitted or
  #     landed (index_entries_one_payment_in_flight). That covers the other
  #     wallet and any other cart, where the pin says nothing.
  #
  # Entries::PaymentSettlement moves a submitted row on from what the chain says.
  module Payment
    extend ActiveSupport::Concern

    STATES = %w[draft submitted landed confirmed].freeze
    IN_FLIGHT = %w[submitted landed].freeze
    TRANSITIONS = {
      "draft" => %w[submitted confirmed],
      "submitted" => %w[draft landed confirmed],
      "landed" => %w[confirmed],
      "confirmed" => []
    }.freeze
    RAILS = %w[managed phantom api].freeze

    # A recent blockhash is good for 150 blocks, so the height read at build
    # time plus this is a ceiling on where the transaction can land.
    BLOCKHASH_LIFETIME_BLOCKS = 150
    # A started charge that never recorded a signature sent nothing (the
    # signature is written before the send), so it is released after this.
    UNSENT_GRACE = 30.seconds
    # The wall-clock floor under a Phantom wire's release. Its stored block
    # height describes the wire the server BUILT; the wallet signs it and may
    # hand back another blockhash, so the height alone does not bind it.
    WALLET_WIRE_FLOOR = OnchainSendVerdict::BLOCKHASH_LAPSE
    SUPPORT_EMAIL = "support@turfmonster.media".freeze

    IN_FLIGHT_MESSAGES = {
      "submitted" => "Your entry was sent and is still confirming on Solana. We are checking it now. " \
                     "You will not be charged twice.",
      "landed" => "Your payment for this contest arrived, but we could not finish the entry. " \
                  "You will not be charged again, and we are sorting it out. " \
                  "If it is not resolved within a day, contact #{SUPPORT_EMAIL}."
    }.freeze

    # A second charge was refused. Controllers answer 409 with the message.
    class InFlight < Refusal
      attr_reader :entry

      def initialize(entry)
        @entry = entry
        super(:payment_in_flight, IN_FLIGHT_MESSAGES.fetch(entry.payment_state, IN_FLIGHT_MESSAGES["submitted"]))
      end
    end

    class IllegalTransition < StandardError; end

    # The row no longer carries the attempt that tried to write it: a
    # settlement released that attempt, or a newer one began. Nothing was
    # written, and the caller sends nothing.
    class Superseded < IllegalTransition; end

    # THE PIN IS HELD. A wire was prepared for this cart (another session, the
    # other rail) and may still be signed and sent, so the cart's wallet and
    # slot cannot be moved under it. 409; nothing was sent.
    class PinHeld < Refusal
      attr_reader :entry

      def initialize(entry)
        @entry = entry
        super(:payment_started_elsewhere, MESSAGES.fetch(:payment_started_elsewhere))
      end
    end

    # A prepared wire reached its send and the cart is no longer pinned to the
    # wallet and ticket the wire pays. Nothing is sent.
    class PinMoved < Refusal
      def initialize
        super(:pin_moved, MESSAGES.fetch(:pin_moved))
      end
    end

    MESSAGES = {
      payment_started_elsewhere: "A payment for these picks was started in another session. Finish it there, or try " \
                                 "again here in a few minutes. Nothing was sent from here and you were not charged.",
      pin_moved: "These picks were changed in another session after this payment was prepared, so nothing was " \
                 "sent and you were not charged. Try again."
    }.freeze
    # How long an unsigned prepared wire holds the pin: past this its blockhash
    # is dead and the confirm that carries it is refused before any send.
    PREPARED_WIRE_HOLD = OnchainSendVerdict::BLOCKHASH_LAPSE

    # Prepended, so the pick writers above keep their cited line numbers.
    module EditGuard
      def toggle_selection!(slate_matchup)
        raise InFlight.new(self) if payment_in_flight?

        super
      end
    end

    included do
      validates :payment_state, inclusion: { in: STATES }
      validates :payment_rail, inclusion: { in: RAILS }, allow_nil: true
      validate :payment_in_flight_row_is_kept, if: -> { will_save_change_to_status?(to: "abandoned") }
      before_save :confirm_payment_with_status
      before_destroy :keep_row_while_payment_in_flight, prepend: true
    end

    class_methods do
      # Contest#reset! only: an operator wiping a contest takes every row.
      def lifting_payment_guard
        previous = Thread.current[:entry_payment_guard_lifted]
        Thread.current[:entry_payment_guard_lifted] = true
        yield
      ensure
        Thread.current[:entry_payment_guard_lifted] = previous
      end

      # This player's unresolved payment in this contest, on either wallet.
      def payment_in_flight_for(user:, contest:)
        scope = where(user_id: user.id, contest_id: contest.id, payment_state: IN_FLIGHT)
        # A row activated by a writer that skipped callbacks (a dyno from before
        # this column, during the deploy) is live, not in flight.
        scope.where(status: %w[active complete]).update_all(payment_state: "confirmed")
        scope.order(:id).first
      end
    end

    def payment_in_flight?
      cart? && IN_FLIGHT.include?(payment_state)
    end

    def payment_slot_pinned_to?(wallet)
      wallet.present? && wallet_address == wallet && !entry_number.nil?
    end

    # The ticket address this row's payment creates, or nil before the pin.
    def payment_entry_pda(vault = Solana::Vault.new(client: nil))
      return nil if wallet_address.blank? || entry_number.nil?

      Solana::Keypair.encode_base58(vault.entry_pda(contest.slug, wallet_address, entry_number).first)
    end

    # Fix the wallet and slot this row pays with. A no-op once pinned to
    # `wallet`.
    #
    # THE PIN IS WALLET AND SLOT TOGETHER, AND IT MOVES ONLY WHEN NOTHING CAN
    # STILL PAY AT IT. An existing pin is moved to another wallet only when the
    # row is a draft, no prepared wire for this cart can still be signed and
    # sent (#payment_wire_prepared?), and the one verdict says the pinned
    # ticket does not exist (Entries::PaymentSettlement: read at `finalized`,
    # and at `confirmed`, where a hit is "wait"). Otherwise the second rail is
    # refused; it never re-pins under the first.
    def pin_payment_slot!(wallet, vault = Solana::Vault.new)
      raise ArgumentError, "a wallet is required to pin an entry slot" if wallet.blank?

      # Asked BEFORE the row lock's transaction: if the ticket is there the
      # verdict confirms the entry, and that write must not roll back with the
      # refusal raised here.
      if payment_pinned_draft? && !payment_slot_pinned_to?(wallet)
        raise PinHeld.new(self) if payment_wire_prepared?
        raise InFlight.new(reload) unless Entries::PaymentSettlement.call(self, vault: vault).idle?
      end

      with_lock do
        raise InFlight.new(self) if payment_in_flight?
        next entry_number if payment_slot_pinned_to?(wallet)
        raise PinHeld.new(self) if payment_pinned_draft? && payment_wire_prepared? # a wire prepared since the check above

        assign_onchain_entry_number!(wallet, vault)
        update!(wallet_address: wallet)
        entry_number
      end
    end

    # draft → submitted. Raises InFlight when this row, or another of the
    # player's rows in this contest, already has a payment unresolved.
    def begin_charge!(rail:)
      other = self.class.payment_in_flight_for(user: user, contest: contest)
      raise InFlight.new(other) if other

      with_lock(requires_new: true) do
        raise InFlight.new(self) if payment_in_flight?
        raise IllegalTransition, "entry #{id} is #{status}/#{payment_state}, not a draft cart" unless cart? && payment_state == "draft"
        raise IllegalTransition, "entry #{id} has no pinned slot" if wallet_address.blank? || entry_number.nil?

        update!(payment_state: "submitted", payment_rail: rail, payment_submitted_at: Time.current,
                payment_signature: nil, payment_last_valid_block_height: nil, payment_refusal_code: nil,
                payment_attempt_token: SecureRandom.hex(12))
      end
      self
    rescue ActiveRecord::RecordNotUnique
      raise InFlight.new(self.class.payment_in_flight_for(user: user, contest: contest) || self)
    end

    # A prepared entry wire for this cart that can still be signed and sent:
    # stamped and unresolved, or unsigned and young enough for its blockhash.
    def payment_wire_prepared?
      wires = PendingTransaction.where(target: self, tx_type: "enter_contest")
      wires.where(status: "submitted").where.not(tx_signature: [nil, ""]).exists? ||
        wires.where(status: %w[pending submitted], created_at: PREPARED_WIRE_HOLD.ago..).exists?
    end

    # The Phantom rail's begin and record in one step, called from the confirm
    # request's before_send. The same signature again (identical bytes resent)
    # is a no-op.
    #
    # THE WIRE MUST PAY THE ROW'S OWN PIN. It was built at prepare for one
    # wallet and one ticket; if the cart is no longer pinned to that wallet, or
    # its ticket address is no longer the one the wire names (`prepared_pda`),
    # this raises PinMoved and nothing is sent. It never adopts a wallet over
    # an existing pin. Only a row that was never pinned (prepared before the
    # pin existed, in flight across the deploy) takes the signing wallet.
    def begin_phantom_charge!(signature:, wallet:, last_valid_block_height: nil, prepared_pda: nil)
      return self if payment_state == "submitted" && payment_signature == signature

      update!(wallet_address: wallet) if payment_state == "draft" && wallet_address.blank? && !entry_number.nil?
      raise PinMoved unless payment_slot_pinned_to?(wallet)
      raise PinMoved if prepared_pda.present? && prepared_pda != payment_entry_pda
      begin_charge!(rail: "phantom")
      record_payment_attempt!(signature: signature, last_valid_block_height: last_valid_block_height)
    end

    # EVERY ATTEMPT OWNS ITS ROW BY A TOKEN. #begin_charge! writes a fresh
    # payment_attempt_token, and every later write an attempt or a verdict makes
    # (the signature, a release, a move to landed, the failure hint) is one
    # UPDATE whose WHERE names the state AND the token the writer holds. A
    # writer holding an older attempt's token changes nothing: it cannot record
    # a signature on, or release, a row a newer attempt has since begun.
    def payment_attempt_scope(token, state: "submitted")
      self.class.where(id: id, payment_state: state, payment_attempt_token: token)
    end

    # "Nothing was sent" for the attempt holding `token`: back to draft, only if
    # the row is still that attempt's and still unsigned. False when it is not.
    def release_unsent_attempt!(token, code)
      released = payment_attempt_scope(token).where(payment_signature: nil)
                                             .update_all(payment_state: "draft", payment_refusal_code: code.to_s, updated_at: Time.current)
      reload
      released == 1
    end

    # Written BEFORE the send, in its own committed write. Raises Superseded
    # when the row is no longer this attempt's (a settlement released it, or a
    # newer attempt began), so the caller sends nothing. `token` defaults to
    # the one this object loaded.
    def record_payment_attempt!(signature:, last_valid_block_height: nil, token: payment_attempt_token)
      written = payment_attempt_scope(token).update_all(
        payment_signature: signature, payment_last_valid_block_height: last_valid_block_height,
        payment_submitted_at: Time.current, updated_at: Time.current
      )
      raise Superseded, "entry #{id}: this attempt was superseded and sent nothing" unless written == 1

      reload
    end

    # One move in the table, as one UPDATE conditional on the state and the
    # attempt token this object loaded: a verdict reached on an older reading
    # of the row cannot move what a newer attempt now holds.
    def transition_payment!(to, **attributes)
      to = to.to_s
      from = payment_state
      return self if from == to

      unless TRANSITIONS.fetch(from).include?(to)
        raise IllegalTransition, "entry #{id}: #{from} → #{to} is not a legal payment move"
      end

      moved = self.class.transaction(requires_new: true) do
        payment_attempt_scope(payment_attempt_token, state: from)
          .update_all(payment_state: to, updated_at: Time.current, **attributes)
      end
      raise Superseded, "entry #{id}: #{from} → #{to} lost to a newer attempt" unless moved == 1

      reload
    end

    # submitted → draft: the attempt provably paid nothing. Picks stay.
    def release_payment!(code)
      transition_payment!("draft", payment_refusal_code: code.to_s)
    end

    # submitted → landed: paid on chain, refused by an app gate.
    def mark_payment_landed!(code:, signature: payment_signature)
      transition_payment!("landed", payment_refusal_code: code.to_s, payment_signature: signature)
    end

    # THE ONE RELEASE RULE: what must be true before a submitted row goes back
    # to draft and its pin can be used for a new payment. Entries::PaymentSettlement
    # is its only caller, and supplies the reads in the order the rule needs:
    # the FINALIZED block height first, then the recorded signature's status,
    # then the ticket at `finalized` (absent, or this is never asked).
    #
    #   * NO SIGNATURE RECORDED: nothing was sent (the signature is committed
    #     before the send), so the grace is all that is waited.
    #   * A SIGNATURE WHOSE STATUS SHOWS AN ERROR, confirmed or finalized: that
    #     wire landed and failed; it cannot pay.
    #   * A SIGNATURE WITH NO STATUS: only when a last valid block height was
    #     recorded AND the finalized height is past it AND, on the Phantom rail,
    #     the wall-clock floor has also passed since the stamp. Every block the
    #     wire could be in is then finalized, and the status and ticket reads
    #     made after that height would have seen it.
    #   * A signature with any other status (seen, not yet confirmed), or with
    #     no recorded height or no stamp time, is never released by a clock.
    def payment_release_allowed?(status:, finalized_block_height:, now: Time.current)
      return payment_submitted_at.nil? || payment_submitted_at <= now - UNSENT_GRACE if payment_signature.blank?
      return %w[confirmed finalized].include?(status["confirmationStatus"]) if status && status["err"]
      return false unless status.nil?
      return false if payment_last_valid_block_height.nil? || finalized_block_height.nil?
      return false if payment_rail == "phantom" && (payment_submitted_at.nil? || payment_submitted_at > now - WALLET_WIRE_FLOOR)

      finalized_block_height.to_i > payment_last_valid_block_height
    end

    # A draft cart whose wallet and slot are fixed: its ticket address is known.
    def payment_pinned_draft?
      cart? && payment_state == "draft" && wallet_address.present? && !entry_number.nil?
    end

    # While a signed attempt is unresolved, remember what its failure looked
    # like (an Entries::PaymentCopy code). A hint only: the chain decides
    # whether the row is released, and the hint then words the reason.
    def note_payment_failure!(code, token: payment_attempt_token)
      payment_attempt_scope(token).update_all(payment_refusal_code: code.to_s)
    end

    private

    def confirm_payment_with_status
      return unless active? || complete?
      return if payment_state == "confirmed"

      self.payment_state = "confirmed"
      self.payment_refusal_code = nil
    end

    def payment_in_flight_row_is_kept
      return unless IN_FLIGHT.include?(payment_state)

      errors.add(:base, IN_FLIGHT_MESSAGES.fetch(payment_state))
    end

    def keep_row_while_payment_in_flight
      throw :abort if payment_in_flight? && !Thread.current[:entry_payment_guard_lifted]
    end
  end
end
