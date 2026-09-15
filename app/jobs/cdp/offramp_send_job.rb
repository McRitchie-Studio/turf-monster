module Cdp
  # Managed-wallet (web2) offramp send — docs/CDP_RAMP_INTEGRATION.md §10.
  # Builds + signs + broadcasts the USDC SPL transfer from the user's web2 ATA
  # to the RESOLVED Coinbase destination (Cdp::OfframpDestination — never the
  # raw to_address), authority = the user's managed keypair, fee payer = admin.
  #
  # This is a server-signed movement of USER funds to an externally supplied
  # address, so every guard is mandatory and fails CLOSED:
  #   - FRESH explicit user confirmation (POST /cdp/offramp/confirm_send stamps
  #     confirmed_at + enqueues; stale/missing confirmation refuses)
  #   - status must be cdp_created (to_address discovered by the poll job)
  #   - refuses past cashout_deadline_at minus a 3-minute safety margin
  #   - on-chain destination resolution (typed error = no send, ever)
  #   - balance check on the user's USDC ATA before signing
  #
  # VERIFY-BEFORE-RETRY (the Lazarus recover_pending_entry bug class): the tx
  # signature is persisted (status → sending) BEFORE the broadcast attempt,
  # and any rerun that finds a persisted signature checks it on-chain via
  # getSignatureStatuses before even considering another send. A new tx is
  # built only after the chain DEFINITIVELY reports the old one failed (err
  # status, or the blockhash window long lapsed with the signature absent).
  # An ambiguous result re-verifies later — it NEVER blind-resends.
  #
  # Confirmation is asynchronous: broadcast → re-enqueue (CONFIRM_WAIT) → the
  # verify path flips sending → sent when getSignatureStatuses confirms. The
  # row therefore never depends on an in-process sleep loop, and a dyno
  # restart mid-confirm recovers on the next run.
  class OfframpSendJob < ApplicationJob
    queue_as :default

    # confirm_send → perform must be tight; an hours-later Sidekiq replay of a
    # stale confirmation must not move funds.
    CONFIRMATION_TTL = 10.minutes
    # §10: refuse sends inside the last 3 minutes of the 30-minute window.
    DEADLINE_SAFETY = 3.minutes
    # Re-check cadence for an in-flight (sending) signature.
    CONFIRM_WAIT = 15.seconds
    # A legacy-blockhash tx is unlandable well before this; a persisted
    # signature still absent from getSignatureStatuses (with
    # searchTransactionHistory) this long after the BROADCAST ATTEMPT
    # (broadcast_at, stamped by mark_sending!) can never land.
    #
    # DEFINED ON THE MODEL since phantom-cashout-needs-sol: the Phantom
    # cash-out cosign endpoint rewinds a row on the same verdict this job does,
    # and two copies of a number that decides "verified-dead vs double-send" is
    # how the two paths drift apart.
    BLOCKHASH_LAPSE = CdpRampTransaction::BLOCKHASH_LAPSE
    # Stop re-verifying an ambiguous signature this long past the cashout
    # deadline — leave the row in :sending for the phase-2 sweep/operator.
    VERIFY_GRACE = 10.minutes

    USDC_BASE_UNITS_PER_USDC = 1_000_000 # 10**6

    def perform(ramp_id:)
      ramp = CdpRampTransaction.find_by(id: ramp_id)
      return Rails.logger.info("[cdp][send] ramp_id=#{ramp_id} gone — stopping") unless ramp

      Current.user = ramp.user
      Current.outbound_source = ramp

      return refuse(ramp, "not an offramp row") unless ramp.offramp?
      return refuse(ramp, "not a managed (web2) wallet — Phantom mode sends client-side") unless ramp.wallet_web2?
      return if ramp.sent? || ramp.terminal?

      # VERIFY-BEFORE-RETRY: a persisted signature means a broadcast was
      # attempted — settle ITS fate on-chain before anything else.
      return verify_pending_send(ramp) if ramp.sent_signature.present?

      return refuse(ramp, "status is #{ramp.status}, requires cdp_created") unless ramp.cdp_created?
      return refuse(ramp, "no fresh user confirmation (confirmed_at=#{ramp.confirmed_at&.iso8601 || 'nil'})") unless freshly_confirmed?(ramp)
      return refuse(ramp, "past cashout deadline safety margin (deadline=#{ramp.cashout_deadline_at&.iso8601 || 'nil'})") unless within_deadline?(ramp)

      keypair = ramp.user.solana_keypair
      return refuse(ramp, "user has no managed keypair") unless keypair
      return refuse(ramp, "managed keypair does not match wallet_address") unless keypair.address == ramp.wallet_address

      amount = amount_base_units(ramp)
      return refuse(ramp, "sell amount missing or not positive") unless amount.positive?
      # The $0.99 floor (phantom-cashout-needs-sol). Cdp::OfframpSendsController
      # #confirm refuses a sub-floor cash-out before this job is ever enqueued,
      # and Vault#build_user_usdc_transfer asserts it again as the unbypassable
      # backstop — but that assertion RAISES, and a raise here re-raises for a
      # Sidekiq retry that could never succeed. Refuse it cleanly instead, so a
      # row created before the floor existed dies quietly rather than looping.
      if amount < Solana::Vault::MIN_WITHDRAWAL_BASE_UNITS
        return refuse(ramp, "below the $#{Solana::Vault::MIN_WITHDRAWAL_USD} minimum withdrawal (#{amount} base units)")
      end

      destination = resolve_destination(ramp)
      return unless destination

      return refuse(ramp, "insufficient USDC balance (need #{amount} base units)") unless balance_covers?(ramp, amount)

      send_transfer(ramp, keypair, destination, amount)
    rescue StandardError => e
      # Job-level fault — ErrorLog with context, then re-raise so Sidekiq
      # retries. A rerun is safe: any persisted signature routes through the
      # verify path, and the unsent paths re-run their guards.
      capture_with_context(e, ramp)
      raise
    end

    private

    # ── Guards ───────────────────────────────────────────────────────────────

    def freshly_confirmed?(ramp)
      ramp.confirmed_at.present? && ramp.confirmed_at >= CONFIRMATION_TTL.ago
    end

    def within_deadline?(ramp)
      ramp.cashout_deadline_at.present? &&
        Time.current <= ramp.cashout_deadline_at - DEADLINE_SAFETY
    end

    def amount_base_units(ramp)
      sell = ramp.sell_amount
      return 0 if sell.nil?
      (sell * USDC_BASE_UNITS_PER_USDC).to_i
    end

    def resolve_destination(ramp)
      Cdp::OfframpDestination.resolve(ramp.to_address, client: vault.client)
    rescue Cdp::OfframpDestination::ResolutionError => e
      # Semantic — retrying won't change the chain. Capture + stop; operator
      # investigates (this is exactly the open-question-3 trap).
      capture_with_context(e, ramp)
      nil
    end

    def balance_covers?(ramp, amount)
      from_ata_bytes, _ = Solana::SplToken.find_associated_token_address(
        ramp.wallet_address, Solana::Config::USDC_MINT
      )
      info = vault.client.get_token_account_balance(Solana::Keypair.encode_base58(from_ata_bytes))
      held = info&.dig("value", "amount")
      held.present? && held.to_i >= amount
    rescue StandardError => e
      # Unreadable balance = hard block, never a pass (mirrors the hardened
      # insufficient-USDC precheck in ContestsController).
      Rails.logger.warn("[cdp][send] #{ramp.partner_user_ref} balance read failed: #{e.class}: #{e.message[0, 120]}")
      false
    end

    # ── Send ─────────────────────────────────────────────────────────────────

    def send_transfer(ramp, keypair, destination, amount)
      built = vault.build_user_usdc_transfer(
        user_keypair: keypair,
        destination_token_account: destination.token_account,
        amount_lamports: amount
      )

      # Durably persist the signature BEFORE the broadcast attempt completes —
      # everything after this line is recoverable via the verify path.
      unless ramp.mark_sending!(built[:signature])
        return refuse(ramp, "state changed before send (now #{ramp.reload.status})")
      end

      Rails.logger.info("[cdp][send] #{ramp.partner_user_ref} broadcasting sig=#{built[:signature]} " \
                        "amount=#{amount} dest=#{destination.token_account} (#{destination.kind})")
      begin
        vault.client.send_transaction(built[:wire_base64])
      rescue Solana::Client::RpcError => e
        # Could be a definitive preflight rejection OR an ambiguous network
        # fault after the bytes left — indistinguishable here. The signature is
        # persisted; let the verify path settle it on-chain. NEVER resend now.
        capture_with_context(e, ramp)
      end
      schedule_verify(ramp)
    end

    # ── Verify-before-retry ──────────────────────────────────────────────────

    def verify_pending_send(ramp)
      status = vault.client.confirm_transaction(ramp.sent_signature).dig("value", 0)

      # The verdict itself is CdpRampTransaction#send_verdict — shared with
      # Cdp::OfframpSendsController#cosign, which rewinds on the same answer.
      # This method still owns what to DO with it (log, reschedule, re-enqueue).
      case ramp.send_verdict(status)
      when :landed
        ramp.mark_sent!
        Rails.logger.info("[cdp][send] #{ramp.partner_user_ref} confirmed on-chain sig=#{ramp.sent_signature} — sent")
      when :failed
        # DEFINITIVE on-chain failure — funds did not move. Safe to clear and
        # rebuild; the fresh attempt re-runs every guard (deadline, freshness,
        # balance, destination).
        Rails.logger.warn("[cdp][send] #{ramp.partner_user_ref} tx failed on-chain " \
                          "err=#{status['err'].inspect} sig=#{ramp.sent_signature} — resetting for a re-guarded attempt")
        ramp.reset_failed_send!
        self.class.perform_later(ramp_id: ramp.id)
      when :never_landed
        # Absent from getSignatureStatuses (searchTransactionHistory) long
        # after the blockhash window — the tx can never land. Verified-dead,
        # not a blind retry.
        Rails.logger.warn("[cdp][send] #{ramp.partner_user_ref} sig=#{ramp.sent_signature} never landed " \
                          "(blockhash window lapsed) — resetting for a re-guarded attempt")
        ramp.reset_failed_send!
        self.class.perform_later(ramp_id: ramp.id)
      else # :ambiguous
        if verify_window_open?(ramp)
          # Ambiguous (in flight / RPC lag) — never resend; check again shortly.
          Rails.logger.info("[cdp][send] #{ramp.partner_user_ref} sig=#{ramp.sent_signature} still ambiguous — re-verifying in #{CONFIRM_WAIT.inspect}")
          schedule_verify(ramp)
        else
          Rails.logger.warn("[cdp][send] #{ramp.partner_user_ref} sig=#{ramp.sent_signature} unresolved past " \
                            "deadline+grace — leaving :sending for the sweep/operator")
        end
      end
    end

    # MOVED TO CdpRampTransaction#blockhash_lapsed? (phantom-cashout-needs-sol),
    # so the cash-out cosign endpoint rewinds on the same rule. The reasoning is
    # kept here because it is the reason the anchor is broadcast_at:
    #
    # Anchored on broadcast_at — the moment mark_sending! persisted the
    # signature, immediately before the broadcast attempt. NEVER anchor on
    # confirmed_at: the broadcast can legally happen up to CONFIRMATION_TTL
    # after the user's confirmation click (Sidekiq queue latency, retry
    # backoff), so a confirmed_at anchor can declare a JUST-broadcast tx
    # verified-dead while it is still inside its blockhash validity — the
    # reset + rebuild then double-sends USDC from the user's wallet.
    # No anchor (shouldn't happen — mark_sending! always stamps it) is
    # AMBIGUOUS, never verified-dead: fall through to the re-verify path,
    # bounded by verify_window_open?.

    def verify_window_open?(ramp)
      deadline = ramp.cashout_deadline_at || (ramp.updated_at + 30.minutes)
      Time.current <= deadline + VERIFY_GRACE
    end

    def schedule_verify(ramp)
      self.class.set(wait: CONFIRM_WAIT).perform_later(ramp_id: ramp.id)
    end

    # ── Plumbing ─────────────────────────────────────────────────────────────

    def vault
      @vault ||= Solana::Vault.new
    end

    # Guard refusals are EXPECTED business outcomes (no exception, no retry) —
    # structured warn so a stuck cash-out is greppable by partner_user_ref.
    def refuse(ramp, reason)
      Rails.logger.warn("[cdp][send][refused] #{ramp.partner_user_ref} #{reason}")
      nil
    end

    # Job-level ErrorLog discipline: nothing escapes unlogged; target = the
    # ramp row, parent = its user (same shape as Cdp::RampPollJob).
    def capture_with_context(exception, ramp)
      error_log = ErrorLog.capture!(exception)
      if ramp
        error_log.target = ramp
        error_log.target_name = ramp.slug
        if ramp.user
          error_log.parent = ramp.user
          error_log.parent_name = ramp.user.slug
        end
        error_log.save!
      end
      Rails.logger.error("[cdp][send][error] ramp=#{ramp&.partner_user_ref} #{exception.class}: #{exception.message}")
    rescue StandardError => e
      Rails.logger.error("[cdp][send][error] ErrorLog capture failed: #{e.class}: #{e.message}")
    end
  end
end
