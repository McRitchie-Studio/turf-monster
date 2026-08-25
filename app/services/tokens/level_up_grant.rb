module Tokens
  # Mints the free-entry token a user earns at each level milestone.
  #
  # THE GAP THIS CLOSES. Levelling up was celebration-only. `User#update_level_
  # from_seeds!` returns the new level so the client can fire confetti and the
  # "you earned a Free Entry Token" modal — and then nothing minted it. The only
  # mint paths were `TokenPurchaseJob` (paid) and an operator clicking Mint on
  # /admin/free_entries. On QA a user reached level 2 with `owed: 1, minted: 0`
  # and stayed there. A fresh seed snapshot now enqueues this grant immediately;
  # the scheduled sweep remains its recovery path.
  #
  # IDEMPOTENCY IS THE WHOLE DESIGN. The EntryTokenAccount PDA is seeded on
  # sha256(source_ref), and the program `init`s it — so re-minting the same ref
  # collides on-chain and CANNOT double-grant. That is why this uses a
  # DETERMINISTIC ref (`levelup:<user_id>:<level>`) and deliberately NOT
  # `Solana::Vault.operator_source_ref`, which appends `SecureRandom.hex(16)`:
  # a random ref is unique per CALL, so a Sidekiq retry after a mint that landed
  # but whose response was lost would mint a SECOND token. With the level in the
  # ref, the chain itself is the ledger of which levels have been paid, the retry
  # is free, and no DB bookkeeping can drift away from the truth.
  #
  # It also means the grant is READ BACK, not remembered: `decode_entry_token`
  # returns `source_ref` as a decoded string, so the already-granted levels fall
  # out of the same `list_entry_tokens` call the caller already needs. No extra
  # RPC, no PDA re-derivation, no state to corrupt.
  #
  # IT NEVER GRANTS OVER AN OPERATOR'S MANUAL MINT. Tokens minted from
  # /admin/free_entries carry random refs, so they are invisible to the
  # level-matching above — and without a second guard, turning this job on would
  # hand a fresh token to every user an operator had already paid by hand. So the
  # mint count is ALSO clamped to `earned_levels - tokens.length`, the exact
  # `owed` figure the admin page computes. The admin page stays the manual
  # backstop, its arithmetic untouched; the two simply cannot pay for the same
  # level twice.
  #
  # "COULD NOT EVALUATE" IS A THIRD ANSWER, NOT A QUIET ZERO. A user whose
  # on-chain read comes back cold is neither paid nor owed-nothing — the service
  # simply does not know. That state is returned EXPLICITLY (`evaluated?` is
  # false, `unevaluable_reason` names why) so the caller is forced to handle it.
  # It used to be returned as `nil`, and the sweep's `if result` skipped it
  # without a word, forever. Money that cannot be verified must be loud.
  class LevelUpGrant
    # Level 1 is the floor everyone starts at — the first grant is for level 2
    # (100 seeds). Level N is worth exactly one token.
    FIRST_REWARDED_LEVEL = 2

    # Per-user ceiling for a single run. A wallet that somehow shows 40 owed
    # levels should not spend 40 admin-SOL rent payments (and 40 devnet RPC
    # slots) inside one run; the recovery sweep picks up the remainder.
    MAX_GRANTS_PER_RUN = 5

    # Rails-side name for the on-chain source byte. `:operator` (0) is the same
    # source the admin page mints under: these ARE operator grants, and the byte
    # has no `:level_up` member on the deployed program (adding one is a
    # turf-vault release, not a Rails change).
    SOURCE = :operator

    # Why a pass could not reach a verdict. Both are DURABLE conditions, not
    # blips: `sync_balance` returns nil only when the RPC answered and there is
    # no UserAccount at that PDA (a transport fault raises instead), so
    # :user_account_missing means "this wallet has no on-chain account" and will
    # keep meaning that until someone creates one.
    UNEVALUABLE_REASONS = {
      no_wallet:             "user has no Solana address to mint to",
      user_account_missing:  "no UserAccount PDA at the user's Solana address — " \
                             "on-chain seeds cannot be read, so nothing can be verified or paid"
    }.freeze

    LevelUpGrantResult = Struct.new(
      :minted_levels, :granted_through, :skipped, :unevaluable_reason, keyword_init: true
    ) do
      def minted_count = minted_levels.length
      def minted? = minted_levels.any?

      # False means the pass reached NO verdict — not "nothing was owed".
      # Callers must branch on this; treating it as a zero is how an unpayable
      # user goes invisible.
      def evaluated? = unevaluable_reason.nil?

      def unevaluable_message = UNEVALUABLE_REASONS[unevaluable_reason]
    end

    def self.unevaluable(reason)
      LevelUpGrantResult.new(
        minted_levels: [], granted_through: nil, skipped: 0, unevaluable_reason: reason
      )
    end

    # THE REF MUST BE UNIQUE ACROSS WALLETS *AND* ACROSS DEPLOYMENTS, because the
    # PDA is derived from the ref ALONE.
    #
    #   Solana::Vault#entry_token_pda(source_ref) =
    #     find_pda([b("entry_token"), sha256(padded_source_ref)], @program_id)
    #
    # There is NO wallet in those seeds — mint_entry_token's own contract comment
    # says source_ref must be globally unique across wallets, and the first
    # version of this file keyed it on `users.id`, a PER-DATABASE integer.
    #
    # WHY THAT COLLIDES FOR REAL, not in theory: SOLANA_PROGRAM_ID defaults to the
    # SAME devnet program for development, test and QA — Solana::Config says so
    # outright, because keeping them byte-identical is deliberate. So QA user 7 at
    # level 2 and a local dev user 7 at level 2 derive ONE account address. The
    # loser's mint raises 0x0 forever, is rescued below, and pages an ErrorLog
    # every 15 minutes with no path to payment. A QA database reset reproduces it
    # wholesale, because the PDAs outlive the database. Production is protected
    # only by having a separate mainnet program — and QA is the gate this work has
    # to pass.
    #
    # So the ref carries BOTH:
    #   * the DEPLOYMENT, so one program serving dev/test/QA cannot cross them;
    #   * the EARNING WALLET, so two users on one deployment cannot cross either.
    #
    # THE WALLET IS HASHED, NOT INLINED, for the 64-byte ceiling
    # (`padded_source_ref` raises past it rather than silently truncating). A
    # base58 address runs to 44 chars: "levelup:" + "development" + a 44-char
    # address + a level is 69 bytes, over the limit for the longest environment
    # name. Sixteen hex characters of sha256 is 41 bytes worst case, and collision
    # across one deployment's users is not a practical concern at 64 bits.
    #
    # DETERMINISM IS PRESERVED, which is the property the whole design rests on:
    # the same wallet at the same level on the same deployment always produces the
    # same ref, so a Sidekiq retry after a lost response still cannot double-grant.
    def self.deployment_namespace
      AppFlags.qa_environment? ? "qa" : Rails.env.to_s
    end

    def self.wallet_key(wallet_address)
      Digest::SHA256.hexdigest(wallet_address.to_s)[0, 16]
    end

    def self.source_ref(wallet_address, level, namespace: deployment_namespace)
      "levelup:#{namespace}:#{wallet_key(wallet_address)}:#{level}"
    end

    # Parses OUR refs back out of an arbitrary token list. Returns the set of
    # levels this WALLET has already been granted ON THIS DEPLOYMENT. Anything
    # else — Stripe/PayPal purchases, an operator's random-ref manual mint, or a
    # levelup ref from another deployment — matches nothing here and is counted
    # only in the `owed` clamp.
    #
    # Deliberately NO legacy `levelup:<user_id>:<level>` fallback: this feature
    # has never merged, so no ref of that shape has ever been minted. Adding one
    # would re-admit the cross-deployment ambiguity the namespace exists to close.
    def self.granted_levels(wallet_address, tokens, namespace: deployment_namespace)
      prefix  = "levelup:#{namespace}:#{wallet_key(wallet_address)}:"
      pattern = /\A#{Regexp.escape(prefix)}(\d+)\z/
      tokens.filter_map { |t| t[:source_ref].to_s[pattern, 1]&.to_i }.to_set
    end

    # The high-water mark stored on the user row: the highest L where every
    # level from FIRST_REWARDED_LEVEL..L is granted. Deliberately NOT
    # `granted.max` — a gap (level 2 granted, 3 failed, 4 granted) must leave
    # the row above the sweep's waterline so the next run retries level 3.
    def self.contiguous_through(granted)
      level = FIRST_REWARDED_LEVEL - 1
      level += 1 while granted.include?(level + 1)
      level
    end

    def self.call(user, vault: nil)
      new(user, vault: vault).call
    end

    def initialize(user, vault: nil)
      @user  = user
      @vault = vault
    end

    # Always returns a LevelUpGrantResult. When `evaluated?` is false the pass
    # reached no verdict, NOTHING was minted, and the waterline was NOT touched
    # — the two must not be confused, because treating it as "nothing owed"
    # would advance the waterline past a level nobody was paid for.
    def call
      address = @user.solana_address
      return self.class.unevaluable(:no_wallet) if address.blank?

      # LIVE read, not the `users.seeds` mirror. The mirror is what SELECTED
      # this user (it can only ever lag, since seeds are monotonic), but a
      # reward is minted against what the chain actually says. A transport
      # failure RAISES out of here on purpose; only a definitive "there is no
      # account at that PDA" comes back as nil.
      seeds = vault.sync_balance(address)&.dig(:seeds)
      return self.class.unevaluable(:user_account_missing) if seeds.nil?

      # Free side-effect: we hold a fresh read, so keep the denormalized
      # seeds/level mirror honest for the admin table and the next sweep's
      # candidate query. Write-on-change only.
      @user.update_level_from_seeds!(seeds)

      earned_levels = seeds / User::SEEDS_PER_LEVEL      # 100 seeds → 1 token owed
      tokens        = vault.list_entry_tokens(address)
      granted       = self.class.granted_levels(address, tokens)

      missing = ((FIRST_REWARDED_LEVEL)..(earned_levels + FIRST_REWARDED_LEVEL - 1)).reject { |l| granted.include?(l) }

      # The admin page's own `owed` arithmetic. Clamps the sweep so a level an
      # operator already paid by hand (random ref, unmatchable above) is not
      # paid a second time.
      owed = [earned_levels - tokens.length, 0].max
      to_mint = missing.first([owed, MAX_GRANTS_PER_RUN].min)

      minted = mint_levels(address, to_mint)

      granted_through = waterline_after(
        earned_levels: earned_levels,
        token_count:   tokens.length + minted.length,
        granted:       granted + minted.to_set
      )
      persist_waterline(granted_through)

      @user.bust_entry_tokens_cache! if minted.any?

      LevelUpGrantResult.new(
        minted_levels:   minted,
        granted_through: granted_through,
        skipped:         missing.length - minted.length
      )
    end

    private

    def vault
      @vault ||= Solana::Vault.new
    end

    # Where to park the candidate-query waterline after a pass.
    #
    # TWO different questions, and using only the second one strands users in
    # the sweep forever. When the debt is CLEARED, the user is paid up through
    # their current level no matter which refs paid them — an operator's manual
    # /admin/free_entries mint carries a random ref this service can never match
    # by level, so a levels-only waterline would leave that user permanently
    # above the line, re-reading their wallet twice every 15 minutes to
    # rediscover that nothing is owed.
    #
    # Only when the debt SURVIVES the pass (a mint raised, or the per-run cap
    # deferred some) does the waterline fall back to the contiguous granted run,
    # which deliberately stops below any gap so the next sweep retries it.
    #
    # Reached only on an EVALUATED pass. An unevaluable user never gets here, so
    # their waterline cannot move on a read that was never made; rotation out of
    # the batch is the sweep cursor's job, not this one's.
    def waterline_after(earned_levels:, token_count:, granted:)
      return earned_levels + 1 if earned_levels - token_count <= 0

      self.class.contiguous_through(granted)
    end

    def mint_levels(address, levels)
      levels.each_with_object([]) do |level, minted|
        # The EARNING wallet, threaded from #call — not a re-read of
        # User#solana_address, which prefers the web3 address and would key the
        # ref to a different wallet than the one being minted to.
        ref = self.class.source_ref(address, level)
        result = vault.mint_entry_token(wallet_address: address, source: SOURCE, source_ref: ref)
        minted << level
        Rails.logger.info(
          "[level-up-grant] minted user=#{@user.id} level=#{level} ref=#{ref} " \
          "sig=#{result[:signature].to_s[0, 16]}..."
        )
      rescue => e
        # Per-level rescue: one wallet's flake must not abandon the levels after
        # it, and must never abort the sweep's other users. A PDA-already-exists
        # collision lands here too and is the SAFE outcome by construction — the
        # token exists, so the next run reads it off the chain and moves the
        # waterline without minting again.
        #
        # SAFE, but not therefore SILENT. A wallet that collides or faults on
        # every run is owed a token it will never receive, and a Rails.logger
        # line summons nobody — the same argument
        # deposits/onchain_reconciler.rb makes on the sibling 15-minute cron.
        # Capture is per LEVEL, and a level leaves the queue as soon as it lands,
        # so a healthy wallet produces no rows at all.
        Rails.logger.warn(
          "[level-up-grant] deferred user=#{@user.id} level=#{level} " \
          "(#{e.class}: #{e.message.to_s[0, 140]})"
        )
        capture_error(e, level: level)
      end
    end

    # Operator-visible record of an owed token that did not land. Telemetry must
    # never change control flow, so a failure to record is itself logged and
    # swallowed (the Coinflow::Fulfillment#record_anomaly! pattern) — it must
    # not convert this level's deferral into an abort of the levels after it.
    def capture_error(exception, level:)
      log = ErrorLog.capture!(exception)
      log.target = @user
      log.target_name = @user.try(:slug)
      log.save!
    rescue StandardError => e
      Rails.logger.error(
        "[level-up-grant] error_log_failed user=#{@user.id} level=#{level} #{e.class}: #{e.message}"
      )
    end

    # `update_column` for the same reason `update_level_from_seeds!` uses it:
    # this is a denormalized mirror of on-chain state, so it must not fire
    # validations on legacy rows or churn `updated_at` on every sweep.
    def persist_waterline(level)
      return if @user.entry_tokens_granted_level == level

      @user.update_column(:entry_tokens_granted_level, level)
    end
  end
end
