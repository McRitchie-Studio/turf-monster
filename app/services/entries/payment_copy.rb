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
      # Sent, outcome not known yet, or known and held.
      pending: [Entry::Payment::IN_FLIGHT_MESSAGES.fetch("submitted"), false],
      landed: [Entry::Payment::IN_FLIGHT_MESSAGES.fetch("landed"), false],
      # A retry found the first payment.
      first_payment_landed: ["Your first payment went through, so you were not charged again. You're in!", false]
    }.freeze

    # Failures after a send that prove the wire paid nothing: the program
    # refused it in simulation (so it was never broadcast), or the cluster
    # processed it and it failed. NOT 0x0: the System program's "already in
    # use" is what this entry's own ticket looks like once it exists.
    PROGRAM_REFUSED = /\ATransaction simulation failed: Error processing Instruction \d+: custom program error: 0x(?:1|17[0-9a-f]{2})\z/i
    LANDED_AND_FAILED = /\ATransaction failed: /
    TICKET_EXISTS = /already in use|"Custom"\s*=>\s*0\b|custom program error: 0x0\b/i
    FEE = /insufficient funds for (fee|rent)|insufficient lamports|no record of a prior credit/i

    def message(code)
      COPY.fetch(code.to_sym) { COPY.fetch(:failed) }.first
    end

    def retry?(code)
      COPY.fetch(code.to_sym) { COPY.fetch(:failed) }.last
    end

    def payload(code)
      { code: code.to_s, error: message(code), retry: retry?(code) }
    end

    def provably_unpaid?(error)
      text = error.message.to_s
      return false if text.match?(TICKET_EXISTS)

      text.match?(PROGRAM_REFUSED) || text.match?(LANDED_AND_FAILED) || text.match?(FEE)
    end

    # The cause code for a failure that paid nothing.
    def code_for(error, sent:)
      text = error.message.to_s
      return :too_late if error.is_a?(Entries::ManagedEntry::SpendTooLate)
      return error.code if error.is_a?(Entry::Refusal) && COPY.key?(error.code)
      return :insufficient_funds if error.is_a?(Entry::Refusal) && error.code == :no_entry_token
      return :network_fee if text.match?(FEE)
      return :contest_locked if text.match?(/0x1773|0x1792|contest has locked|contest is not open/i)
      return :contest_full if text.match?(/0x1774|contest is full/i)
      return :insufficient_funds if text.match?(/custom program error: 0x1\b|0x1772|not enough usdc/i)
      return :program_refused if text.match?(PROGRAM_REFUSED) || text.match?(LANDED_AND_FAILED)
      return :rpc_unreachable if !sent && (error.is_a?(Solana::Client::RpcError) || error.is_a?(Solana::Deadline::Exceeded))

      :failed
    end
  end
end
