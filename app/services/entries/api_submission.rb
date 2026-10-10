module Entries
  # Create and fund one entry for an agent, in one call, at most once.
  # POST /api/v1/contests/:slug/entries (docs/AGENT_API.md).
  #
  # It adds two things to Entries::ManagedEntry, which does the gating, the
  # spend and the confirm for the browser too:
  #
  #   1. NO CART. The browser builds a `cart` row one tap at a time and enters
  #      it later. The API never reads or writes that row. It builds its own
  #      entry INSIDE the contest lock's transaction, so the row exists only if
  #      the spend commits: a refused or failed request leaves no entry behind,
  #      and the player's web cart for the contest is exactly as they left it.
  #
  #   2. AT MOST ONE SPEND PER Idempotency-Key. See below.
  #
  # ── WHAT STOPS A SECOND SPEND ───────────────────────────────────────────────
  #
  # An ApiEntryRequest row per (player, key), moved only by this class, and
  # only one of a player's requests for a contest may be running at a time
  # (#acquire, under the player's row lock). For a retry of a key:
  #
  #   succeeded   replay the stored response, while its entry exists. Nothing runs.
  #   void        the contest was reset: 409, for good. Nothing runs (#replay).
  #   executing   another request holds the key: 409, come back shortly.
  #   failed      the last attempt spent nothing, with certainty: run again.
  #   confirming  the entry row exists and is paid: finish confirming it.
  #   uncertain   the last attempt reached the chain call and its outcome is
  #               unknown. In order: (a) if an entry row was committed, it is
  #               paid, so finish it; (b) look on chain for a paid ticket with
  #               no entry row and, if there is one, build the entry on it;
  #               (c) if the transaction could still land, answer 503 and
  #               spend nothing; (d) only once it cannot land, run again.
  #
  # WHY (b) IS SOUND. On chain an entry is a ContestEntry account at
  # (contest, wallet, slot) and nothing else: a ticket, with no picks in it. A
  # ticket whose slot no entry row holds is a payment with no entry. Whichever
  # request it came from, giving it to this player's pending request is one
  # payment, one entry. (A contest Reset also leaves such tickets behind; the
  # reconciler adopts those on the same reasoning, and only a request already
  # in doubt ever looks.)
  #
  # WHY (c) HAS A CLOCK. Entries are signed against a fresh blockhash, never a
  # durable nonce, so a transaction that has not landed within about 90 seconds
  # never will. ApiEntryRequest::SETTLE_WINDOW is that bound with margin.
  #
  # WHAT COUNTS AS "SPENT NOTHING, WITH CERTAINTY". Anything raised before
  # ManagedEntry#spend_attempted? turns true. After it, ONLY a failure on the
  # short list in #proven_unlanded?: the program itself refusing the
  # instruction, in simulation or in a landed-and-failed transaction. A Solana
  # transaction is atomic, so those moved nothing. EVERYTHING ELSE after the
  # chain call is `uncertain`, including messages that read like a rejection.
  # The list is an allow-list on purpose: the Solana client re-posts the same
  # transaction after a read timeout, and when the first post landed the
  # re-post is answered "Transaction simulation failed: This transaction has
  # already been processed". That is proof of a LANDING. Reading every
  # "simulation failed" as a rejection recorded it `failed`, and the retry paid
  # a second time (PR 846 review).
  #
  # AND A SECOND LINE BEHIND THAT ONE. Every paid request, in whatever state
  # its key was left, looks for a paid ticket with no entry row INSIDE the
  # contest lock before it builds an entry (#build_entry). A wrong
  # classification therefore costs a lookup, not a second payment.
  #
  # A SUPERSEDED ATTEMPT DOES NOT SPEND. The in-flight timeout is an assumption
  # about how long a request lives, not a limit on it: a slow RPC or a queue on
  # the contest lock can keep an attempt alive after a retry has been licensed
  # to take its key. So ownership is checked again INSIDE the contest lock
  # (#fence!): before the entry is built, and once more immediately before the
  # chain call. An attempt that no longer owns the row stops, having spent
  # nothing. An attempt that does own it first looks at what the lock's
  # previous holder left: a committed entry (finish that instead), a spend
  # still in doubt (wait), a paid ticket (adopt it).
  #
  # WHAT THIS DOES NOT COVER. A process killed in the middle of its chain call,
  # after outliving both clocks, while a retry of the same key is already
  # waiting on the contest lock: the retry cannot see a transaction nobody
  # lived to record. And the settle window is wall-clock, not the
  # transaction's own lastValidBlockHeight.
  #
  # A NEW KEY DOES NOT ESCAPE AN OLD DOUBT. Before a request spends, every other
  # unsettled request this player has for the contest is settled first
  # (#settle_others!): adopted, waited on, or marked failed. So an agent that
  # gives up on a key after a 503 and mints a new one cannot pay twice either.
  class ApiSubmission
    # What the controller renders. `error_code` is nil on a success.
    Result = Struct.new(:status, :body, :error_code, :message, :retry_after, :replayed, keyword_init: true) do
      def error? = !error_code.nil?
    end

    # Raised inside a run to stop without spending: the chain could not answer,
    # or a transaction may still be in flight.
    class ChainUnavailable < StandardError
      attr_reader :retry_after

      def initialize(message = nil, retry_after: 5)
        @retry_after = retry_after
        super(message || MESSAGES[:chain_unavailable])
      end
    end

    STATUSES = Hash.new(:unprocessable_entity).merge(
      idempotency_key_reused: :conflict,
      idempotency_in_progress: :conflict,
      chain_unavailable: :service_unavailable
    ).freeze

    # The API's own wording, where the model's message is written for the
    # website (or names an admin page). Codes not listed use the refusal's own.
    MESSAGES = {
      unsupported_contest: "This contest ran a retired format. It takes no entries; its final standings are on turfmonster.media.",
      contest_cancelled: "This contest was cancelled.",
      coming_soon: "This contest is not open for entries yet.",
      contest_not_open: "This contest is not open for entries.",
      contest_locked: "This contest has locked. Entries are closed.",
      no_entry_token: "This account holds no free entry token, and USDC was not allowed. Nothing was spent. " \
                      "Send allow_usdc: true to pay the entry fee in USDC instead.",
      no_entry_token_usdc_off: "This account holds no free entry token, and paying an entry fee in USDC " \
                               "is not available right now. Nothing was spent.",
      insufficient_funds: "The wallet does not hold enough USDC for the entry fee. Nothing was spent.",
      wallet_not_server_signable: "This account's wallet signs its own entries (it is self-custodied or linked " \
                                  "to Phantom), or the account has no wallet. Enter on turfmonster.media instead.",
      idempotency_key_reused: "This Idempotency-Key was already used for a different request. " \
                              "Use a new key for a new request.",
      contest_reset: "This contest was reset after this Idempotency-Key was used, and the entry it made " \
                     "no longer exists. This key is finished and will not enter again. Use a new key.",
      entry_gone: "This Idempotency-Key was used by an entry that no longer exists. Use a new key.",
      idempotency_in_progress: "A request to enter this contest is still running for this player. " \
                               "Nothing new was started. Retry with the same Idempotency-Key in a moment.",
      chain_unavailable: "The Solana network could not confirm this just now. Retry with the same " \
                         "Idempotency-Key: the server looks for the payment before it pays again."
    }.freeze

    # Solana::ErrorInterpreter's blocker reasons, as API codes.
    BLOCKER_CODES = {
      "no_funding" => :insufficient_funds,
      "insufficient_balance" => :insufficient_funds,
      "contest_locked" => :contest_locked,
      "contest_full" => :contest_full,
      "web3_step_up_required" => :wallet_not_server_signable
    }.freeze

    # THE ALLOW-LIST: the only failures after a chain call that prove nothing
    # landed. Each is the PROGRAM refusing the instruction, which a transaction
    # that landed cannot produce:
    #
    #   * a simulation that failed on a custom program error from turf-vault
    #     (Anchor codes 6000 and up: 0x1770..0x17ff) or on SPL's insufficient
    #     funds (0x1). Not 0x0: that is the System program's "already in use",
    #     which is what a slot looks like when our own transaction just filled it.
    #   * a transaction the cluster processed and reports as failed.
    #
    # "already been processed", "already in use", an expired blockhash, a
    # timeout, and anything not written here are NOT on it.
    PROGRAM_REFUSED_IN_SIMULATION =
      /\ATransaction simulation failed: Error processing Instruction \d+: custom program error: 0x(?:1|17[0-9a-f]{2})\z/i
    LANDED_AND_FAILED = /\ATransaction failed: /
    NEVER_PROOF = /already been processed|already in use|custom program error: 0x0\b|"Custom"\s*=>\s*0\b/i # 0x0 in either shape the RPC gives it

    # A signal from inside the contest lock that this attempt must not spend.
    class Superseded < StandardError; end

    # Another attempt committed this key's entry while this one waited.
    class AlreadyEntered < StandardError; end

    # A paid ticket with no entry row turned up inside the contest lock.
    class TicketFound < StandardError
      attr_reader :orphan

      def initialize(orphan)
        @orphan = orphan
        super("a paid ticket is on chain")
      end
    end

    # Refusals whose own message names the team, the count or the limit.
    DETAILED_CODES = %i[invalid_picks team_locked entry_limit_reached duplicate_lineup contest_full].freeze

    PENDING_RETRY_AFTER = 5
    BUSY_RETRY_AFTER = 2

    # serializer: entry -> Hash, the read shape of GET /api/v1/entries/:slug.
    def initialize(user:, contest:, matchup_ids:, allow_usdc:, idempotency_key:, serializer:, api_key: nil)
      @user = user
      @contest = contest
      @matchup_ids = matchup_ids.map(&:to_i)
      @allow_usdc = allow_usdc ? true : false
      @idempotency_key = idempotency_key
      @serializer = serializer
      @api_key = api_key
    end

    def call
      record, verdict = acquire

      case verdict
      when :reused then error(:idempotency_key_reused)
      when :busy   then error(:idempotency_in_progress, retry_after: BUSY_RETRY_AFTER)
      when :replay then replay(record)
      else Solana::Deadline.long_budget(:api_entry_submission) { run(record) }
      end
    end

    private

    # ── The claim ────────────────────────────────────────────────────────────
    #
    # Under the player's row lock, so that of all this player's requests for
    # this contest AT MOST ONE is `executing` and in flight. That is what makes
    # everything after it single-threaded per player and contest: the duplicate
    # lineup check, the slot probe, and the orphan adoption below.
    def acquire
      @user.with_lock do
        now = Time.current
        record = ApiEntryRequest.find_by(user_id: @user.id, idempotency_key: @idempotency_key)

        if record
          next [record, :reused] if record.fingerprint != fingerprint
          next [record, :replay] if record.succeeded? || record.void? # void: #replay refuses it, nothing runs
          next [record, :busy] if record.in_flight?(now)
        end
        next [record, :busy] if another_in_flight?(record, now)

        # Read BEFORE the claim overwrites the state it is derived from. A
        # `confirming` row whose entry has since been deleted (a contest reset)
        # is a paid ticket with no entry again: the same doubt.
        @uncertain_since = record&.uncertain_since(now)
        @uncertain_since ||= record.updated_at if record&.confirming?

        record ||= ApiEntryRequest.new(user: @user, contest: @contest, idempotency_key: @idempotency_key,
                                       fingerprint: fingerprint, matchup_ids: @matchup_ids, allow_usdc: @allow_usdc)
        record.update!(state: "executing", attempted_at: now, attempts: record.attempts + 1, api_key: @api_key)
        @attempt = record.attempts
        [record, :run]
      end
    end

    def another_in_flight?(record, now)
      ApiEntryRequest.where(user_id: @user.id, contest_id: @contest.id, state: "executing")
                     .where("attempted_at > ?", now - ApiEntryRequest::IN_FLIGHT_TIMEOUT)
                     .where.not(id: record&.id)
                     .exists?
    end

    def fingerprint
      @fingerprint ||= ApiEntryRequest.fingerprint(contest: @contest, matchup_ids: @matchup_ids, allow_usdc: @allow_usdc)
    end

    # ── One attempt ──────────────────────────────────────────────────────────

    def run(record)
      # (a) An entry row this request committed. The lock transaction only
      # commits after the spend (ManagedEntry), so the row is paid for.
      return converge(record) if committed_entry(record)

      # (b) (c) A spend of our own that may be outstanding.
      if @uncertain_since
        orphan = find_orphan
        return adopt(record, orphan) if orphan
        wait_for_settlement!(@uncertain_since)
      end

      settle_others!(record)
      execute(record)
    rescue Superseded
      # Not ours any more: the row is the newer attempt's to write.
      error(:idempotency_in_progress, retry_after: BUSY_RETRY_AFTER)
    rescue AlreadyEntered
      @committed_entry = nil
      converge(record.reload)
    rescue TicketFound => e
      adopt(record, e.orphan)
    rescue ChainUnavailable => e
      settle_doubt(record)
      error(:chain_unavailable, retry_after: e.retry_after)
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      # An adoption that lost a race for the slot or the signature to another
      # row (a web entry in mid-flight). Nothing was spent by this request.
      log_error(e, record)
      settle_doubt(record)
      error(:chain_unavailable, retry_after: PENDING_RETRY_AFTER)
    end

    # Our own doubt is kept, with its original clock; a fresh request that
    # merely had to wait spent nothing.
    def settle_doubt(record)
      since = @uncertain_since || record.class.where(id: record.id).pick(:spend_uncertain_at)
      if since
        mark(record, state: "uncertain", spend_uncertain_at: since, last_error_code: "chain_unavailable")
      else
        mark(record, state: "failed", last_error_code: "chain_unavailable")
      end
    end

    # THE FENCE. Called inside the contest lock, so it is serialized with every
    # other managed spend on this contest and reads what the lock's previous
    # holder committed. Raises unless this attempt still owns the key.
    def fence!(record)
      state, attempts, entry_id, doubt = ApiEntryRequest.where(id: record.id)
                                                        .pick(:state, :attempts, :entry_id, :spend_uncertain_at)
      raise Superseded unless state == "executing" && attempts == @attempt

      [entry_id, doubt]
    end

    def execute(record)
      assert_submittable!

      assert_token_or_usdc! if paid_contest?

      managed = Entries::ManagedEntry.new(contest: @contest, user: @user,
                                          usdc_allowed: @allow_usdc && AppFlags.web2_usdc_entry?,
                                          before_spend: ->(_entry) { fence!(record) })
      outcome = managed.call { build_entry(record) }

      record.update!(funding_method: outcome.funding_method || "free", token_consumed: outcome.token_consumed)
      outcome.entry.active? ? succeed(record, outcome.entry) : pending(record)
    rescue ChainUnavailable, Superseded, AlreadyEntered, TicketFound
      raise
    rescue StandardError => e
      settle_failure(record, managed, e)
    end

    # Built inside the contest lock's transaction (ManagedEntry#call yields
    # there), so the row and the record's pointer to it commit together with
    # the spend or not at all.
    #
    # First, what the lock's previous holder may have left for this key: an
    # earlier attempt that was still alive when this one was licensed.
    def build_entry(record)
      committed_id, doubt = fence!(record)
      raise AlreadyEntered if committed_id && Entry.exists?(committed_id)

      if paid_contest?
        wait_for_settlement!(doubt) if doubt
        # Leave the lock's transaction before building on it: #adopt writes
        # rows that must not roll back with a spend that never happens.
        orphan = find_orphan
        raise TicketFound.new(orphan) if orphan
      end

      entry = @contest.entries.create!(user: @user, status: :cart)
      picked_matchups.each { |matchup| entry.selections.create!(slate_matchup: matchup) }
      record.update!(entry: entry)
      # Attribute the RPC writes this entry spawns (OutboundRequestLogger).
      Current.outbound_source = entry
      entry
    end

    def picked_matchups
      @picked_matchups ||= @contest.slate.slate_matchups.where(id: @matchup_ids).to_a
    end

    # The gates that need no entry row, so a doomed request creates nothing.
    # Entry#assert_enterable! repeats the ones it owns under the contest lock.
    def assert_submittable!
      refuse(:unsupported_contest) if @contest.retired_format?
      refuse(:contest_cancelled) if @contest.cancelled?
      refuse(:coming_soon) if @contest.coming_soon?
      refuse(:contest_not_open) unless @contest.open?
      refuse(:contest_locked) if @contest.locked?

      required = @contest.picks_required
      unless @matchup_ids.size == required && @matchup_ids.uniq.size == required
        refuse(:invalid_picks, "matchup_ids must list exactly #{required} different teams.")
      end
      unless (@matchup_ids - @contest.pickable_matchup_ids).empty?
        refuse(:invalid_picks, "matchup_ids must come from this contest's teams[].matchup_id.")
      end

      refuse(:wallet_not_server_signable) unless server_signable?
    end

    # The server may sign only for a wallet it alone holds: managed, never
    # exported, with no Phantom wallet linked beside it.
    def server_signable?
      @user.wallet_kind == :managed && !@user.self_custodied? &&
        @user.encrypted_web2_solana_private_key.present?
    end

    # TOKEN ONLY BY DEFAULT, decided on a read that cannot
    # lie. The browser path reads tokens through User#cached_entry_tokens, which
    # turns an unreadable chain into "no tokens" so a navbar never 500s. Here
    # that would be wrong twice: with allow_usdc off it would tell an agent its
    # player has no token when we simply could not look, and with allow_usdc on
    # it would spend USDC while a free token sat unread. So: drop the 60-second
    # cache, read the chain, and let a failed read be chain_unavailable. The
    # read warms the cache ManagedEntry's own lookup then hits.
    def assert_token_or_usdc!
      @user.bust_entry_tokens_cache!
      tokens = Solana::Vault.new.list_entry_tokens(@user.web2_solana_address)
      return if tokens.any? { |token| !token[:consumed] }
      return if @allow_usdc && AppFlags.web2_usdc_entry?

      refuse(:no_entry_token, MESSAGES[@allow_usdc ? :no_entry_token_usdc_off : :no_entry_token])
    rescue Entry::Refusal
      raise
    rescue StandardError => e
      Rails.logger.warn("[api][entry] token read failed user=#{@user.id} #{e.class}: #{e.message.to_s[0, 140]}")
      raise ChainUnavailable
    end

    def refuse(code, message = nil)
      raise Entry::Refusal.new(code, message || MESSAGES.fetch(code))
    end

    # ── After an attempt ─────────────────────────────────────────────────────

    def succeed(record, entry)
      record.update!(state: "succeeded", entry: entry, spend_uncertain_at: nil, last_error_code: nil)

      run_effects(record, entry)

      json = JSON.generate(success_body(record, entry))
      record.update!(response_status: 201, response_body: json)
      Result.new(status: :created, body: JSON.parse(json))
    end

    # The chat announcement and the seeds side effects of a web entry
    # (ContestsController#enter). Best-effort: the entry is already confirmed.
    def run_effects(record, entry)
      Message.announce_join!(contest: @contest, user: @user)
      Entries::PostEntryEffects.call(entry: entry, user: @user, contest: @contest, path: "api",
                                     tx_signature: entry.onchain_tx_signature,
                                     token_consumed: record.token_consumed)
    rescue StandardError => e
      log_error(e, record)
    end

    def success_body(record, entry)
      { entry: @serializer.call(entry), funding: funding(record) }.as_json
    end

    def funding(record)
      { method: record.funding_method || "unknown", token_consumed: record.token_consumed }
    end

    # Paid, entry row on file, not active yet. 202: come back with the same key.
    def pending(record)
      mark(record, state: "confirming", spend_uncertain_at: nil)
      body = { entry: nil, funding: funding(record), pending: true, retry_after: PENDING_RETRY_AFTER }.as_json
      Result.new(status: :accepted, body: body, retry_after: PENDING_RETRY_AFTER)
    end

    # A 201 describes an entry, so it is replayed only while that entry exists.
    #
    #   void       the contest was reset after this request settled
    #              (ApiEntryRequest.void_for_reset!).
    #   no entry   the entry row was deleted some other way: the foreign key
    #              nulls entry_id, and the stored response is no longer true.
    #
    # Either way the key is finished. It answers the same 409 every time and
    # never runs again: a retry is the OLD request, and running it would enter
    # the player a second time without anyone having asked.
    def replay(record)
      return error(:idempotency_key_reused, MESSAGES[:contest_reset]) if record.void?

      entry = record.entry
      return error(:idempotency_key_reused, MESSAGES[:entry_gone]) if entry.nil?

      # The stored text, parsed: key order survives, so a replay renders the
      # same bytes the first response did. Without one (the request died
      # between confirming and storing), the entry is described as it is now.
      body = record.response_body ? JSON.parse(record.response_body) : success_body(record, entry)
      Result.new(status: :created, body: body, replayed: true)
    end

    def committed_entry(record)
      return nil if record.entry_id.nil?

      @committed_entry ||= Entry.find_by(id: record.entry_id)
    end

    # Finish an entry whose row is on file: with its signature this is the
    # reconciler's fast path (no RPC), without it the reconciler asks the chain
    # for the ticket at the row's slot.
    def converge(record)
      entry = committed_entry(record)
      unless entry.active? || entry.complete?
        outcome = Entries::OnchainReconciler.reconcile_entry(entry)
        entry.reload
        if outcome != :reconciled && !entry.active?
          # A free or off-chain entry the reconciler does not handle, left
          # behind by a confirm that failed: there is no payment to honour.
          return discard_unpaid(record, entry) if entry.onchain_tx_signature.blank? && !paid_contest?

          return pending(record)
        end
      end

      succeed(record, entry)
    end

    def paid_contest?
      @contest.onchain? && @contest.entry_fee_cents.to_i.positive?
    end

    def discard_unpaid(record, entry)
      entry.destroy!
      @committed_entry = nil
      record.update!(entry: nil)
      settle_others!(record)
      execute(record)
    end

    # What to do with an exception out of ManagedEntry. `managed` is nil when
    # the request never got that far.
    def settle_failure(record, managed, exception)
      spent = managed&.spend_attempted?
      entry = managed&.entry && Entry.find_by(id: managed.entry.id)
      code, message = classify(exception)
      # A refusal is an answer, not a fault. A fault with no code is re-raised
      # below and logged once, by the controller.
      log_error(exception, record) unless exception.is_a?(Entry::Refusal) || code.nil?

      if entry && (spent || entry.active?)
        # The lock transaction committed. With a spend, that means the spend
        # landed and something after it failed (the durable capture): the row is
        # paid, finish it later. Without one, the entry confirmed and only the
        # bookkeeping after it failed. Either way the entry stands.
        record.funding_method ||= managed.funding_method || "free"
        record.token_consumed = managed.token_consumed? if record.token_consumed.nil?
        Entries::OnchainReconcileJob.perform_later(entry.id) if spent
        return pending(record)
      end

      if spent && !proven_unlanded?(exception)
        # Written to the ROW first, not only through this attempt's claim: if a
        # retry has taken the key meanwhile, its fence reads this clock.
        now = Time.current
        ApiEntryRequest.where(id: record.id).update_all(spend_uncertain_at: now)
        mark(record, state: "uncertain", spend_uncertain_at: now, last_error_code: "chain_unavailable")
        return error(:chain_unavailable, retry_after: PENDING_RETRY_AFTER)
      end

      # Nothing was spent. A free entry whose confirm failed left its row
      # committed; remove it so no half-made entry survives a failed request.
      entry&.destroy!
      mark(record, state: "failed", entry: nil, spend_uncertain_at: nil, last_error_code: (code || :internal_error).to_s)
      raise exception if code.nil?

      error(code, message, retry_after: (PENDING_RETRY_AFTER if code == :chain_unavailable))
    end

    # Whether a failure raised AFTER the chain call proves nothing landed.
    # See PROGRAM_REFUSED_IN_SIMULATION: an allow-list, and the unknown is not on it.
    def proven_unlanded?(exception)
      message = exception.message.to_s.strip
      return false if message.match?(NEVER_PROOF)

      message.match?(PROGRAM_REFUSED_IN_SIMULATION) || message.match?(LANDED_AND_FAILED)
    end

    # [code, message], or [nil, nil] for a fault that is ours (the controller
    # answers 500 and it is logged).
    def classify(exception)
      # The player has a payment unresolved in this contest (from the website,
      # on either wallet). To an agent that is the answer it already knows:
      # something is still running for this player, wait and resend.
      return [:idempotency_in_progress, MESSAGES[:idempotency_in_progress]] if exception.is_a?(Entry::Payment::InFlight)

      if exception.is_a?(Entry::Refusal)
        code = exception.code
        # Our own refusals already carry API wording; the model's are replaced
        # where they are written for the website, and kept where they name the
        # team or the limit.
        message = MESSAGES.value?(exception.message) ? exception.message : (MESSAGES[code] || exception.message)
        message = MESSAGES[:no_entry_token_usdc_off] if code == :no_entry_token && @allow_usdc
        message = exception.message if DETAILED_CODES.include?(code)
        return [code, message]
      end

      reason = Solana::ErrorInterpreter.interpret(exception, contest: @contest, mode: "web2").dig(:blocker, :reason)
      code = BLOCKER_CODES[reason]
      return [code, MESSAGES[code] || "The contest refused this entry. Nothing was spent."] if code
      return [:chain_unavailable, MESSAGES[:chain_unavailable]] if chain_error?(exception)

      [nil, nil]
    end

    def chain_error?(exception)
      exception.is_a?(Solana::Client::RpcError) ||
        exception.message.to_s.match?(/simulation failed|custom program error|blockhash|timed out|timeout|connection (refused|reset)|network error/i)
    end

    # ── Settling a doubt ─────────────────────────────────────────────────────

    def wait_for_settlement!(since)
      remaining = (since + ApiEntryRequest::SETTLE_WINDOW - Time.current).ceil
      raise ChainUnavailable.new(retry_after: remaining) if remaining.positive?
    end

    # Every OTHER request of this player's for this contest that could still
    # have a spend outstanding. None of them can be running: #acquire admits
    # one live request per player and contest, and this is it.
    def settle_others!(record)
      now = Time.current
      ApiEntryRequest.where(user_id: @user.id, contest_id: @contest.id, state: %w[uncertain executing])
                     .where.not(id: record.id).order(:id).each do |other|
        next unless other.unsettled?(now)
        next if other.entry_id && Entry.exists?(other.entry_id) # paid row on file; its own retry or the job finishes it

        if (orphan = find_orphan)
          # Activate it NOW, before this request goes on to its own gates: the
          # duplicate-lineup and per-player-limit checks count active entries,
          # and a paid entry still waiting to be confirmed would be invisible
          # to them. If it will not activate, nothing new is spent behind it.
          entry = adopt_for(other, orphan)
          Entries::OnchainReconciler.reconcile_entry(entry)
          unless entry.reload.active?
            Entries::OnchainReconcileJob.perform_later(entry.id)
            raise ChainUnavailable
          end
          next
        end

        wait_for_settlement!(other.uncertain_since(now))
        other.update!(state: "failed", spend_uncertain_at: nil, last_error_code: "unspent")
      end
    end

    # A paid ticket on chain that no entry row holds: [slot, pda, signature],
    # or nil. FAILS CLOSED: if the chain cannot be read the answer is not "no
    # ticket", it is ChainUnavailable, because "no ticket" licenses a spend.
    def find_orphan
      return nil unless paid_contest?

      wallet = @user.web2_solana_address
      return nil if wallet.blank?

      vault = Solana::Vault.new
      held = @contest.entries.where(user_id: @user.id, status: %i[cart active complete])
                     .where.not(entry_number: nil).pluck(:entry_number)

      (0...@contest.max_entries_per_user).each do |slot|
        next if held.include?(slot)

        pda = Solana::Keypair.encode_base58(vault.entry_pda(@contest.slug, wallet, slot).first)
        info = vault.client.get_account_info(pda)
        next unless info&.dig("value", "owner") == Solana::Config::PROGRAM_ID # a ticket is the PROGRAM's account; dust sent to the address is not one
        next if @contest.entries.exists?(onchain_entry_id: pda)

        signature = creating_signature(vault, pda)
        raise ChainUnavailable if signature.nil?
        next if Entry.exists?(onchain_tx_signature: signature)

        return [slot, pda, signature]
      end
      nil
    rescue ChainUnavailable
      raise
    rescue StandardError => e
      Rails.logger.warn("[api][entry] orphan probe failed user=#{@user.id} contest=#{@contest.slug} #{e.class}: #{e.message.to_s[0, 140]}")
      raise ChainUnavailable
    end

    # The oldest success among the address's last 20, read as the entry that
    # created the ticket. STILL THE OLD RULE: dust sent to the address is a
    # success too, so use Solana::CreatingSignature (PaymentSettlement does).
    def creating_signature(vault, pda)
      rows = vault.client.send(:call, "getSignaturesForAddress", [pda, { "limit" => 20 }]) # private in the gem; answers newest first
      hit = Array(rows).reverse.find { |row| row && row["err"].nil? }
      hit && hit["signature"]
    end

    def adopt(record, orphan)
      adopt_for(record, orphan)
      @committed_entry = nil
      converge(record)
    end

    # Build `record`'s entry on a ticket that is already paid for. The row goes
    # in as `cart` carrying its proof, the shape Entry#confirm! and the
    # reconciler both expect, and is confirmed straight away.
    def adopt_for(record, orphan)
      slot, pda, signature = orphan
      entry = nil
      Entry.transaction do
        entry = @contest.entries.create!(user: @user, status: :cart, entry_number: slot,
                                         onchain_tx_signature: signature, onchain_entry_id: pda)
        @contest.slate.slate_matchups.where(id: record.matchup_ids).each do |matchup|
          entry.selections.create!(slate_matchup: matchup)
        end
        # With allow_usdc off the only way to have paid is the token.
        record.update!(entry: entry, state: "confirming", spend_uncertain_at: nil,
                       funding_method: record.allow_usdc ? nil : "token",
                       token_consumed: record.allow_usdc ? nil : true)
      end
      @user.bust_entry_tokens_cache!
      Rails.logger.info("[api][entry][adopted] request=#{record.id} entry_id=#{entry.id} slot=#{slot} tx=#{signature.to_s.first(8)}...")
      entry
    end

    # ── Small things ─────────────────────────────────────────────────────────

    # A state write that must not turn a decided outcome into a 500. If it
    # fails the row stays `executing`, goes stale, and is read as `uncertain`,
    # which is the safe direction.
    def mark(record, **attributes)
      record.update!(**attributes)
    rescue StandardError => e
      Rails.logger.error("[api][entry] state write failed request=#{record.id} #{e.class}: #{e.message.to_s[0, 140]}")
    end

    def error(code, message = nil, retry_after: nil)
      Result.new(status: STATUSES[code], error_code: code, message: message || MESSAGES.fetch(code),
                 retry_after: retry_after)
    end

    def log_error(exception, record)
      error_log = ErrorLog.capture!(exception)
      # The entry when there is one (the house rule), else the player.
      target = (record&.entry_id && Entry.find_by(id: record.entry_id)) || @user
      error_log.target = target
      error_log.target_name = target.slug if target.respond_to?(:slug)
      error_log.parent = @contest
      error_log.parent_name = @contest.slug
      error_log.save!
    rescue StandardError => e
      Rails.logger.error("[api][entry] error log failed request=#{record&.id} #{e.class}: #{e.message.to_s[0, 140]}")
    end
  end
end
