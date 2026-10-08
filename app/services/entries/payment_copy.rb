module Entries
  # What a player is told when a payment does not end in an entry, by cause.
  # Every sentence says what happened, whether money moved, and what to do. A
  # failure the page shows is always one of these codes, never a raw error.
  #
  # `retry` is whether the page offers "Try again" at once. It is always SAFE
  # to try again (Entry::Payment: the pinned slot and the in-flight key); the
  # flag only says whether trying again can help yet.
  module PaymentCopy
    extend self

    COPY = {
      # Nothing was sent.
      rpc_unreachable: ["We could not reach the Solana network, so nothing was sent and you were not charged. " \
                        "Your picks are saved. Try again in a moment.", true],
      too_late: ["Solana is responding slowly, so we stopped before sending anything. You were not charged. " \
                 "Your picks are saved. Try again.", true],
      not_sent: ["Your last attempt stopped before anything was sent, so you were not charged. " \
                 "Your picks are saved. Try again.", true],
      # Sent, and the chain or the clock says it paid nothing.
      expired: ["Your last attempt never reached Solana, so you were not charged. Your picks are saved. Try again.", true],
      network_fee: ["We could not cover the Solana network fee for your entry. That is on our side, and you were not " \
                    "charged. Your picks are saved. Try again in a few minutes.", true],
      insufficient_funds: ["There is not enough USDC in your wallet for the entry fee, so nothing was charged. " \
                           "Add funds and try again. Your picks are saved.", true],
      contest_locked: ["This contest locked before your entry reached Solana. You were not charged.", false],
      contest_full: ["This contest filled before your entry reached Solana. You were not charged.", false],
      program_refused: ["Solana turned this entry down, so you were not charged. Your picks are saved. Try again; " \
                        "if it happens again, contact support.", true],
      failed: ["Your entry did not go through and you were not charged. Your picks are saved. Try again.", true],
      failed_onchain: ["Your last attempt reached Solana and was turned down there, so you were not charged. " \
                       "Your picks are saved. Try again.", true],
      funds_or_fee: ["Solana could not take the entry fee, so you were not charged. Check that your wallet holds " \
                     "enough USDC and try again. If it does, the problem is on our side and we are fixing it.", true],
      check_failed: ["We could not check your last payment just now, so nothing was changed and nothing was " \
                     "charged. Try again in a moment.", true],
      payment_started_elsewhere: [Entry::Payment::MESSAGES.fetch(:payment_started_elsewhere), true],
      pin_moved: [Entry::Payment::MESSAGES.fetch(:pin_moved), true],
      # Sent, outcome not known yet, or known and held.
      pending: [Entry::Payment::IN_FLIGHT_MESSAGES.fetch("submitted"), false],
      landed: [Entry::Payment::IN_FLIGHT_MESSAGES.fetch("landed"), false],
      # A retry found the first payment.
      first_payment_landed: ["Your first payment went through, so you were not charged again. You're in!", false]
    }.freeze

    # The two ways the RPC reports a refusal: preflight simulation (the wire was
    # never broadcast) and a transaction the cluster processed and failed.
    SIMULATION_FAILED = /\ATransaction simulation failed: /
    LANDED_AND_FAILED = /\ATransaction failed: /
    FEE = /insufficient funds for (fee|rent)|insufficient lamports|no record of a prior credit/i

    # turf-vault's error numbers (programs/turf_vault/src/errors.rs).
    INSUFFICIENT_BALANCE = 6002
    CONTEST_NOT_OPEN = 6003
    CONTEST_FULL = 6004
    CONTEST_LOCKED = 6034

    def message(code)
      COPY.fetch(code.to_sym) { COPY.fetch(:failed) }.first
    end

    def retry?(code)
      COPY.fetch(code.to_sym) { COPY.fetch(:failed) }.last
    end

    def payload(code)
      { code: code.to_s, error: message(code), retry: retry?(code) }
    end

    # The program error number in a failure, from either shape the RPC gives
    # it: `custom program error: 0x1774` (simulation) or
    # `{"InstructionError"=>[0, {"Custom"=>6004}]}` (a landed failure).
    def error_number(error)
      text = error.message.to_s
      if (hex = text[/custom program error: 0x([0-9a-f]+)/i, 1]) then hex.to_i(16)
      elsif (decimal = text[/"?Custom"?\s*(?:=>|:)\s*(\d+)/, 1]) then decimal.to_i
      end
    end

    # The System program's "already in use" (custom error 0): what this
    # entry's own ticket looks like once it exists. Never a sign that nothing
    # was paid.
    def ticket_exists?(error)
      error_number(error) == 0 || error.message.to_s.match?(/already in use/i)
    end

    # Whether the failure's TEXT says the chain refused the wire. It words the
    # reason and nothing more: a signed attempt is released only by
    # Entries::PaymentSettlement, from the chain.
    def chain_refusal?(error)
      text = error.message.to_s
      return false if ticket_exists?(error) || text.match?(/already been processed/i)

      text.match?(SIMULATION_FAILED) || text.match?(LANDED_AND_FAILED) || text.match?(FEE)
    end

    # The cause code for a failure. `funding` and `funds_confirmed` are what
    # the managed spend knew when it sent: custom error 1 is "insufficient
    # funds" from SPL (the player's USDC) AND "insufficient lamports" from the
    # System program (the HOUSE wallet's SOL, which pays the ticket's rent).
    # A token entry moves no USDC, and a balance just read as enough rules the
    # player out, so those are ours; otherwise the sentence names both.
    def code_for(error, sent:, funding: nil, funds_confirmed: false)
      text = error.message.to_s
      return :too_late if error.is_a?(Entries::ManagedEntry::SpendTooLate)
      return error.code if error.is_a?(Entry::Refusal) && COPY.key?(error.code)
      return :insufficient_funds if error.is_a?(Entry::Refusal) && error.code == :no_entry_token
      return :network_fee if text.match?(FEE)

      case error_number(error)
      when 1 then return funding == "token" || funds_confirmed ? :network_fee : :funds_or_fee
      when INSUFFICIENT_BALANCE then return :insufficient_funds
      when CONTEST_NOT_OPEN, CONTEST_LOCKED then return :contest_locked
      when CONTEST_FULL then return :contest_full
      when Integer then return :program_refused
      end
      return :contest_locked if text.match?(/contest has locked|contest is not open/i)
      return :contest_full if text.match?(/contest is full/i)
      return :insufficient_funds if text.match?(/not enough usdc/i)
      return :program_refused if text.match?(SIMULATION_FAILED) || text.match?(LANDED_AND_FAILED)
      return :rpc_unreachable if !sent && (error.is_a?(Solana::Client::RpcError) || error.is_a?(Solana::Deadline::Exceeded))

      :failed
    end
  end
end
