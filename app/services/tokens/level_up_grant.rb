module Tokens
  # Mints the free-entry token a user earns at each level milestone.
  #
  # THE GAP THIS CLOSES. Levelling up was celebration-only. `User#update_level_
  # from_seeds!` returns the new level so the client can fire confetti and the
  # "you earned a Free Entry Token, it will arrive in 48 hours" modal — and then
  # nothing minted it. The only mint paths were `TokenPurchaseJob` (paid) and an
  # operator clicking Mint on /admin/free_entries, and no scheduled job ever
  # pressed that button. On QA a user reached level 2 with `owed: 1, minted: 0`
  # and stayed there. Those 48 hours are now a real deadline this job meets, not
  # a hope that someone visits the admin page.
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
  class LevelUpGrant
    # Level 1 is the floor everyone starts at — the first grant is for level 2
    # (100 seeds). Level N is worth exactly one token.
    FIRST_REWARDED_LEVEL = 2

    # Per-user ceiling for a single run. A wallet that somehow shows 40 owed
    # levels should not spend 40 admin-SOL rent payments (and 40 devnet RPC
    # slots) inside one sweep; the remainder is picked up next run, which is
    # still hours inside the 48-hour promise.
    MAX_GRANTS_PER_RUN = 5

    # Rails-side name for the on-chain source byte. `:operator` (0) is the same
    # source the admin page mints under: these ARE operator grants, and the byte
    # has no `:level_up` member on the deployed program (adding one is a
    # turf-vault release, not a Rails change).
    SOURCE = :operator

    LevelUpGrantResult = Struct.new(:minted_levels, :granted_through, :skipped, keyword_init: true) do
      def minted_count = minted_levels.length
      def minted? = minted_levels.any?
    end

    # `levelup:<user_id>:<level>` — 64-byte budget is not a concern (a 9-digit
    # id at level 9999 is 27 bytes), but `padded_source_ref` raises past 64 so
    # the ceiling is enforced for us rather than silently truncating.
    def self.source_ref(user_id, level)
      "levelup:#{user_id}:#{level}"
    end

    # Parses OUR refs back out of an arbitrary token list. Returns the set of
    # levels this user has already been granted. Anything else on the wallet —
    # Stripe/PayPal purchases, an operator's random-ref manual mint — matches
    # nothing here and is counted only in the `owed` clamp.
    def self.granted_levels(user_id, tokens)
      pattern = /\Alevelup:#{user_id}:(\d+)\z/
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

    # Returns a LevelUpGrantResult, or nil when the user could not be evaluated
    # (no wallet, or a cold on-chain read). Nil is "ask again next run", never
    # "nothing was owed" — the two must not be confused, because the second
    # would advance the waterline past a level nobody was paid for.
    def call
      address = @user.solana_address
      return nil if address.blank?

      # LIVE read, not the `users.seeds` mirror. The mirror is what SELECTED
      # this user (it can only ever lag, since seeds are monotonic), but a
      # reward is minted against what the chain actually says.
      seeds = vault.sync_balance(address)&.dig(:seeds)
      return nil if seeds.nil?

      # Free side-effect: we hold a fresh read, so keep the denormalized
      # seeds/level mirror honest for the admin table and the next sweep's
      # candidate query. Write-on-change only.
      @user.update_level_from_seeds!(seeds)

      earned_levels = seeds / User::SEEDS_PER_LEVEL      # 100 seeds → 1 token owed
      tokens        = vault.list_entry_tokens(address)
      granted       = self.class.granted_levels(@user.id, tokens)

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
    def waterline_after(earned_levels:, token_count:, granted:)
      return earned_levels + 1 if earned_levels - token_count <= 0

      self.class.contiguous_through(granted)
    end

    def mint_levels(address, levels)
      levels.each_with_object([]) do |level, minted|
        ref = self.class.source_ref(@user.id, level)
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
        Rails.logger.warn(
          "[level-up-grant] deferred user=#{@user.id} level=#{level} " \
          "(#{e.class}: #{e.message.to_s[0, 140]})"
        )
      end
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
