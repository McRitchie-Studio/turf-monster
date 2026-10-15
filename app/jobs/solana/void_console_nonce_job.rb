module Solana
  # KILL the wire an ended signer-console row was built on, by advancing its
  # console nonce (Solana::ConsoleNonce#void!).
  #
  # A nonce-anchored update_signers never expires, and turf-vault does not pin
  # the set it replaces, so a signed rotation that ended without landing (a
  # cancel, the 30-minute expiry, a refused or rejected broadcast) could be
  # sent later and re-apply its old set. Advancing the nonce is its only
  # death. Admin::AuthoritiesController enqueues this on every such ending;
  # the build path also voids synchronously before reusing a value.
  #
  # Only an EXPIRED row is voided. A pending row is live (the operator may be
  # signing), and a submitted one is awaiting its verdict: #reconcile owns it.
  class VoidConsoleNonceJob < ApplicationJob
    queue_as :default

    # The chain could not be read, or did not confirm the advance. The wire may
    # still land, so keep trying. When the last attempt fails too, say so on
    # the row: an ErrorLog targeting it is what tells an operator a signed
    # rotation may still be landable.
    class StillLandable < StandardError; end
    retry_on StillLandable, wait: :polynomially_longer, attempts: 8 do |job, error|
      row = PendingTransaction.find_by(id: job.arguments.first)
      log = ErrorLog.capture!(error)
      log.update!(target: row, target_name: row.slug) if row
    end

    # The nonce still holds the value and this server is not its authority: a
    # server-key change stranded it. Raised once, logged, never retried.
    class Unvoidable < StandardError; end

    def perform(row_id)
      row = PendingTransaction.find_by(id: row_id)
      return :gone unless row && row.status == "expired"

      meta = row.parsed_metadata["console_nonce"].presence
      return :not_a_nonce_row unless meta

      outcome = ConsoleNonce.new(vault: Vault.new).void!(pubkey: meta["pubkey"], value: meta["value"])
      case outcome
      when :unread
        raise StillLandable, "#{row.slug}: console nonce #{meta['pubkey']} still holds its built value"
      when :unvoidable
        log = ErrorLog.capture!(Unvoidable.new(
          "#{row.slug}: console nonce #{meta['pubkey']} still holds its built value and this server is not its " \
          "authority. Advance it with the old server key, or unseat one of the rotation's authorizers."
        ))
        log.update!(target: row, target_name: row.slug)
      end
      outcome
    end
  end
end
