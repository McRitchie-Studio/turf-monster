module Entries
  # Submit one entry for a player whose wallet the SERVER signs for: gate it,
  # pay for it on-chain, and activate it.
  #
  # ONE PATH, TWO CALLERS. ContestsController#enter (the browser's hold-to-confirm)
  # and Entries::ApiSubmission (the agent API) both end here, so the ordering this
  # class exists to protect cannot drift between them. It was lifted out of
  # ContestsController, where it lived as #enter's `with_lock` block,
  # #resolve_web2_entry_funding! and #finalize_managed_entry!; the browser's
  # behaviour is unchanged and test/controllers/contests_enter_characterization_test.rb
  # holds it there.
  #
  # THE ORDER IS THE INVARIANT (docs/workflows/submit-entry-decision-tree.md §0):
  #
  #   1. inside the contest row lock, every reversible gate: Entry#assert_enterable!,
  #      a configured season, an on-chain Contest PDA for a paid contest;
  #   2. still inside the lock, the IRREVERSIBLE spend (#fund!): an entry token
  #      consumed, or USDC transferred;
  #   3. outside the lock, the durable capture: the signature and Entry PDA
  #      written onto the still-`cart` row, so nothing after it can erase the
  #      fact that the player paid;
  #   4. Entry#confirm!. If it fails AFTER a spend the failure is swallowed, an
  #      ErrorLog is written and Entries::OnchainReconcileJob is queued: the
  #      entry is paid and must converge to `active`, not invite a second spend.
  #
  # Incident 2026-06-08 is why 1 precedes 2: the consume once ran before a gate,
  # the gate failed, and a player was paid on-chain and `cart` in the app. A
  # reconciler cannot heal a genuine validation failure, so gates run first and
  # only TRANSIENT failures are left for it.
  #
  # WHAT A CALLER SUPPLIES.
  #   usdc_allowed   whether the USDC fallback may be used when the wallet holds
  #                  no entry token. The browser passes AppFlags.web2_usdc_entry?;
  #                  the API passes that AND the request's own allow_usdc, so an
  #                  agent never spends USDC it was not told to.
  #   entry / block  the entry to submit, or a block that builds it. The block
  #                  runs INSIDE the contest lock's transaction, so an entry it
  #                  creates exists only if the spend commits: a refused or
  #                  failed submission leaves no row behind.
  #
  # THE PAYMENT STATE MACHINE (Entry::Payment). #fund! pins the wallet and slot,
  # moves the row to `submitted`, and hands the vault a hook that commits the
  # signature BEFORE the send. Then the two callers differ in one thing:
  #
  #   * the browser's entry is a committed cart, so the gates run under the
  #     contest lock and the spend runs AFTER it. Every payment write is then
  #     its own commit, visible to the next request and to the sweep, and a
  #     raise cannot roll it back. BEFORE any gate or funding check, a cart that
  #     already has a pinned slot is asked whether its ticket exists
  #     (#first_payment_landed?): if it does, an earlier payment landed and the
  #     entry is confirmed with nothing built or sent. A failure is resolved in
  #     #resolve_failed_charge!: an attempt that recorded no signature sent
  #     nothing, so the cart returns to draft and the error re-raises; a SIGNED
  #     attempt is released only by Entries::PaymentSettlement, from the chain,
  #     whatever the error text says, and an answer still unknown raises
  #     PendingConfirmation, which the controller answers as "pending".
  #   * the API's entry is built by the block inside the lock's transaction, so
  #     its spend stays inside it and the row exists only if the spend commits.
  #     Entries::ApiSubmission keeps its own durable record of the attempt.
  #
  # WHAT IT TELLS A CALLER AFTERWARDS. #spend_attempted? is true from the moment
  # just before the chain call that moves money. A caller that must decide
  # whether a failure could have spent (the API's idempotency record) reads it;
  # an exception raised while it is false spent nothing, with certainty.
  class ManagedEntry
    Outcome = Struct.new(:entry, :tx_signature, :onchain_entry_id, :token_consumed, :funding_method,
                         keyword_init: true)

    attr_reader :entry, :tx_signature, :onchain_entry_id, :funding_method

    # Why THIS attempt returned the cart to draft (an Entries::PaymentCopy
    # code), or nil. The row's payment_refusal_code can be an older attempt's.
    attr_reader :failure_code

    # The send happened and its outcome is not known yet. Entries::PaymentSettleJob
    # is queued; the row stays `submitted` until the chain answers.
    class PendingConfirmation < StandardError
      attr_reader :entry

      def initialize(entry)
        @entry = entry
        super(Entry::Payment::IN_FLIGHT_MESSAGES.fetch("submitted"))
      end
    end

    # Raised from the before-send hook: nothing was sent. Not an Entry::Refusal,
    # because it is the browser request's own clock and no rule of the contest.
    class SpendTooLate < StandardError
      def initialize = super(Entries::PaymentCopy.message(:too_late))
    end

    # A request must answer before the router cuts it at 30 seconds. With less
    # than this left a spend is not started; the confirm wait ends this far
    # before the deadline.
    MIN_SECONDS_TO_SEND = 8
    CONFIRM_MARGIN = 4

    # before_spend: called with the entry inside the contest lock, immediately
    # before each chain call that moves money. Raising there stops the
    # submission having spent nothing. The API uses it to fence an attempt a
    # retry has superseded; the browser passes none.
    def initialize(contest:, user:, usdc_allowed:, before_spend: nil, rail: "managed")
      @contest = contest
      @user = user
      @usdc_allowed = usdc_allowed
      @before_spend = before_spend
      @rail = rail
      @spend_attempted = false
      @token_consumed = false
      @sent = false
      # The request's own deadline, read now: a send releases Current's copy.
      @deadline = Solana::Deadline.current
    end

    def spend_attempted? = @spend_attempted
    def token_consumed? = @token_consumed
    # This call found an earlier payment's ticket and confirmed the entry from it.
    def first_payment_found? = @first_payment_found == true

    def call(entry = nil)
      if entry
        @entry = entry
        return outcome(entry) if first_payment_landed?(entry)

        @contest.with_lock { preflight!(entry) }
        charge!(entry) if paid_onchain?
        return outcome(entry) if entry.active? # a settlement already activated it
      else
        # The API: the block builds the entry inside the lock's transaction.
        @contest.with_lock do
          @entry = entry = yield
          preflight!(entry)
          spend!(entry) if paid_onchain?
        end
      end

      # Durable capture (incident 2026-06-08). The on-chain consume/transfer
      # above is IRREVERSIBLE — the token is spent + the Entry PDA exists on
      # chain. Persist that proof onto the (still-`cart`) entry NOW, in a write
      # that has already left the with_lock transaction, so the gate-running
      # confirm! below can fail without erasing the fact that the user paid.
      # A strand is then a recoverable row (`cart` + onchain_tx_signature) that
      # self-heals via Entries::OnchainReconcileJob / `rake entries:reconcile_onchain`.
      entry.update!(onchain_tx_signature: @tx_signature, onchain_entry_id: @onchain_entry_id) if @tx_signature

      finalize!(entry)
      outcome(entry)
    end

    # uiAmount dollars (Float | Integer | nil from Solana::Vault#fetch_wallet_balances)
    # → integer cents. BigDecimal so on-chain money is never compared through float
    # drift; nil (mint unconfigured / no ATA) → 0, and we FLOOR — both fail closed
    # so a missing or sub-cent balance can never read as enough to fund.
    def self.dollars_to_cents(dollars)
      return 0 if dollars.nil?
      (BigDecimal(dollars.to_s) * 100).floor
    end

    private

    def outcome(entry)
      Outcome.new(entry: entry, tx_signature: @tx_signature, onchain_entry_id: @onchain_entry_id,
                  token_consumed: @token_consumed, funding_method: @funding_method)
    end

    def paid_onchain?
      @contest.onchain? && @contest.entry_fee_cents > 0
    end

    # Every reversible gate, under the contest row lock, BEFORE any spend
    # (incident 2026-06-08): a raise here leaves the token unconsumed and the
    # entry a cart.
    def preflight!(entry)
      entry.assert_enterable!
      @preflight_at = Time.current # confirm! judges its time gates as of this pass (Entry#assert_enterable! as_of:)

      # On-chain entries require a configured season (seed_schedule lives on its PDA).
      if @contest.onchain? && SeasonConfig.current_season_id.to_i.zero?
        raise Entry::Refusal.new(:contest_not_open, "No active season configured. Set one at /admin/seasons before users can enter on-chain contests.")
      end

      # A paid contest must be backed by an on-chain Contest PDA: an off-chain
      # paid contest has no payment rail, so refuse rather than create a free
      # entry. (Entry#confirm! enforces the same gate as a model-level backstop.)
      if @contest.entry_fee_cents.to_i.positive? && !@contest.onchain?
        raise Entry::Refusal.new(:contest_not_open, "This contest isn't on-chain yet — paid entry is unavailable.")
      end
    end

    # The spend keeps the gem's 15s wait budget and runs outside the request deadline: a stopped confirm poll strands a paid entry.
    def spend!(entry)
      Solana::Deadline.long_budget(:managed_entry_spend) { Solana::Client.with_wait_budget(Solana::Client::DEFAULT_WAIT_BUDGET) { fund!(entry) } }
    end

    # The browser's spend, with every failure resolved to a state the player
    # can act on.
    def charge!(entry)
      spend!(entry)
    rescue Entry::Payment::InFlight
      raise
    rescue StandardError => e
      raise unless entry.reload.payment_state == "submitted" # refused before the charge began

      resolve_failed_charge!(entry, e)
    end

    # THE PINNED TICKET IS READ FIRST, on every retry. A cart whose earlier
    # payment landed has already spent its token or its USDC, so the funding
    # checks below would turn it away as unfunded; and a cart that cannot be
    # read must not be charged on a guess.
    def first_payment_landed?(entry)
      return false unless entry.payment_pinned_draft?

      settled = Entries::PaymentSettlement.call(entry)
      raise Solana::Client::RpcError, "the entry's ticket could not be read; nothing was sent" if settled.unreadable?
      raise Entry::Payment::InFlight.new(entry.reload) if settled.pending? || settled.landed?
      return false unless settled.confirmed?

      @tx_signature = entry.onchain_tx_signature
      @onchain_entry_id = entry.onchain_entry_id
      @first_payment_found = true
    end

    def resolve_failed_charge!(entry, error)
      unless @sent # no signature was recorded, so nothing was sent
        @failure_code = failure_code_for(error)
        entry.release_payment!(@failure_code)
        raise error
      end

      # A signed attempt. What the error text says is kept as a hint for the
      # sentence; whether the row is released is the chain's to say.
      if Entries::PaymentCopy.chain_refusal?(error)
        hint = failure_code_for(error)
        entry.note_payment_failure!(hint)
        ErrorLog.capture!(error) if hint == :network_fee # ours to fix: the house wallet is short
      end

      settled = Entries::PaymentSettlement.call(entry)
      case settled.status
      when :confirmed
        @tx_signature = entry.onchain_tx_signature
        @onchain_entry_id = entry.onchain_entry_id
      when :released
        @failure_code = settled.code
        raise error
      when :landed then raise Entry::Payment::InFlight.new(entry)
      else
        Entries::PaymentSettleJob.perform_later(entry.id)
        raise PendingConfirmation.new(entry)
      end
    end

    def failure_code_for(error)
      Entries::PaymentCopy.code_for(error, sent: @sent, funding: @funding_method, funds_confirmed: @usdc_confirmed == true)
    end

    def seconds_left
      @deadline && (@deadline - Solana::Deadline.clock)
    end

    # Handed to the vault, which calls it with the signature and the wire's
    # block-height ceiling after signing and before sending.
    def record_attempt(entry)
      lambda do |signature, ceiling|
        left = seconds_left
        raise SpendTooLate if left && left < MIN_SECONDS_TO_SEND

        entry.record_payment_attempt!(signature: signature, last_valid_block_height: ceiling)
        @sent = true
      end
    end

    def confirm_timeout
      -> { (left = seconds_left) ? (left - CONFIRM_MARGIN).clamp(2, 30) : 30 }
    end

    # Managed-wallet entry funding — runs INSIDE the contest lock, after
    # entry.assert_enterable!, on a paid on-chain contest. Funding priority
    # (the operator's order):
    #   1. ENTRY TOKEN (incl. seed-earned free entries) — atomic on-chain consume
    #      via enter_contest_with_token (no USDC transfer; token IS the payment).
    #   2. USDC, only when the caller allows it — the server signs the existing
    #      enter_contest (USDC) instruction with the managed keypair
    #      (Solana::Vault#enter_contest_with_usdc). This is what lets a USDC
    #      contest payout fund the next entry.
    #   3. else refuse ("No entry tokens"). For the browser, Solana::ErrorInterpreter
    #      maps the message to the no_funding blocker; the API answers
    #      `no_entry_token`.
    # USDT is deliberately NOT offered here (payouts are USDC).
    #
    # Everything derives from the managed (web2) address so a managed+phantom
    # combo account signs with — and spends from — the custodial wallet the server
    # holds, never the web3 address (which User#solana_address would otherwise
    # prefer and desync from the keypair). The IRREVERSIBLE consume/transfer is
    # durably captured by #call immediately after the lock (incident 2026-06-08).
    def fund!(entry)
      address = @user.web2_solana_address
      if address.blank?
        raise Entry::Refusal.new(:wallet_not_server_signable, "Managed wallet missing keypair (cannot sign entry)")
      end

      vault = Solana::Vault.new
      # Pin the wallet and slot (probed once; every retry reuses them), then
      # open the charge. Entry::Payment::InFlight from either is the refusal
      # of a second charge.
      entry.pin_payment_slot!(address, vault)
      entry.begin_charge!(rail: @rail)

      # Token detection MUST be scoped to the SAME web2 `address` we sign with.
      # User#next_unconsumed_entry_token reads #solana_address (web3-preferred for a
      # combo account), so for a managed+phantom account it would surface a
      # web3-OWNED token the managed keypair can't consume (doomed owner != signer)
      # AND mask an available USDC fallback — a confusing hard wall. Scoping to the
      # web2 address makes the token sub-path derive from the same wallet the USDC
      # sub-path's signer guard already pins.
      token = @user.next_unconsumed_entry_token_for(address)
      if token
        vault.ensure_user_account(address, username: @user.username) if @user.solana_connected?
        keypair = @user.solana_keypair
        @funding_method = "token"
        @before_spend&.call(entry)
        @spend_attempted = true
        # OPSEC-004: the token owner (managed keypair) must sign the consume.
        result = vault.enter_contest_with_token(
          address, @contest.slug, entry.entry_number, token[:pda],
          user_keypair: keypair, season_id: @contest.season_id,
          before_send: record_attempt(entry), confirm_timeout: confirm_timeout
        )
        # The on-chain EntryTokenAccount.consumed flag just flipped to true. Bust
        # the 60s entry-tokens cache so a follow-up entry within the same TTL
        # doesn't re-pick this token and trip 0x177f (EntryTokenAlreadyConsumed).
        @user.bust_entry_tokens_cache!
        @token_consumed = true
      elsif @usdc_allowed
        # SAFETY NET (2026-06-13): pre-check the USDC balance BEFORE the
        # irreversible on-chain enter. A fresh managed wallet with no USDC ATA
        # reads `null` client-side, slips past the hold-time eligibilityBlocker
        # (which fails OPEN on null), and would otherwise attempt a doomed SPL
        # transfer that fails with "custom program error: 0x1" (insufficient
        # funds) — a cryptic sim error. Validate before the side effect (backend
        # discipline #2): underfunded → refuse, never broadcast a doomed entry.
        # FRESH authoritative read — the 60s navbar cache is not trusted here.
        #
        # FAIL-OPEN ON A READ FAILURE: read with
        # raise_on_read_error so a transient getTokenAccountsByOwner flake RAISES
        # rather than masquerading as $0 — a confirmed-zero must block, but a
        # FLAKED read must NOT false-block a funded user (whose atomic SPL transfer
        # would have succeeded). On a read failure, fall through to the atomic
        # enter and let it be the authority: it succeeds for a funded wallet, and
        # fails 0x1 for a genuine $0 — which ErrorInterpreter ALREADY backstops to
        # no_funding/web2. Only a CONFIRMED-insufficient balance refuses here.
        fee_cents = @contest.entry_fee_cents.to_i
        begin
          usdc_cents = self.class.dollars_to_cents(vault.fetch_wallet_balances(address, raise_on_read_error: true)[:usdc])
          if usdc_cents < fee_cents
            raise Entry::Refusal.new(:insufficient_funds, "Not enough USDC to enter this contest — top up your wallet and try again.")
          end
          @usdc_confirmed = true # a fresh read says the player can pay; a 0x1 after this is not theirs
        rescue Solana::Client::RpcError
          # Balance read flaked — defer to the self-protecting atomic enter below.
        end

        @funding_method = "usdc"
        @before_spend&.call(entry)
        @spend_attempted = true
        # enter_contest_with_usdc encapsulates the web2-address/keypair/username
        # resolution + ensure_user_account + ensure_ata(USDC) preamble, so the
        # signer/ATA-desync footgun can't reach the call site. Atomic SPL transfer
        # + entry-PDA init — an underfunded ATA fails the whole TX (no strand).
        result = vault.enter_contest_with_usdc(
          user: @user, contest: @contest, entry_num: entry.entry_number,
          before_send: record_attempt(entry), confirm_timeout: confirm_timeout
        )
      else
        raise Entry::Refusal.new(:no_entry_token, "No entry tokens. Buy at /tokens/buy")
      end

      @tx_signature = result[:signature]
      @onchain_entry_id = result[:entry_pda]
    end

    # Flip the cart entry to `active` now that payment has settled (on-chain
    # consume/transfer done, or a free contest). For an on-chain-paid entry whose
    # proof we already durably captured, a confirm! failure must NOT strand the
    # user or invite a double-spend retry: the token/USDC is already gone on chain
    # and the Entry PDA exists, so the entry IS valid — we schedule the reconciler
    # to converge the Rails row to active out-of-band and let the caller's success
    # stand (the durable onchain_tx_signature keeps the row recoverable). A free /
    # off-chain entry has nothing to recover, so its confirm! failure re-raises as
    # a normal error. (Incident 2026-06-08.)
    def finalize!(entry)
      entry.confirm!(tx_signature: @tx_signature, onchain_entry_id: @onchain_entry_id, as_of: @preflight_at)
    rescue StandardError => e
      raise e if @tx_signature.blank?

      Rails.logger.error(
        "[entry][post-broadcast-confirm-failed] entry_id=#{entry.id} " \
        "contest=#{@contest.slug} user_id=#{entry.user_id} " \
        "tx=#{@tx_signature.to_s.first(8)}... #{e.class}: #{e.message} — " \
        "scheduling reconcile (token already consumed on-chain)"
      )

      # This branch SWALLOWS the exception (the on-chain payment already settled, so
      # the entry is valid and reconciles out-of-band) — which means a caller's
      # rescue_and_log never sees it. Persist an ErrorLog ourselves, with the same
      # target/parent context rescue_and_log would attach, so a stranded entry is
      # diagnosable in seconds (this exact failure class is what incident #133 was
      # reconstructed from log scraping). Capture BEFORE the enqueue.
      error_log = ErrorLog.capture!(e)
      error_log.target = entry
      error_log.target_name = entry.slug
      error_log.parent = @contest
      error_log.parent_name = @contest.slug
      error_log.save!

      Entries::OnchainReconcileJob.perform_later(entry.id)
    end
  end
end
