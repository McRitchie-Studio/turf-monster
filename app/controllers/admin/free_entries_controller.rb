module Admin
  class FreeEntriesController < ApplicationController
    before_action :require_admin

    SEEDS_PER_LEVEL = User::SEEDS_PER_LEVEL # 100
    PER_PAGE        = 10

    # How long a background warm is considered "in flight" so repeated
    # page-nav within the token cache's own 60s TTL doesn't fan out duplicate
    # refresh jobs. Matches the entry-token list cache TTL.
    REFRESH_GUARD_TTL = 60.seconds

    def index
      scope         = users_with_wallet.order(:id)
      @total_users  = scope.count
      @page         = [params[:page].to_i, 1].max
      @total_pages  = [(@total_users.to_f / PER_PAGE).ceil, 1].max
      @page         = @total_pages if @page > @total_pages
      paged_users   = scope.limit(PER_PAGE).offset((@page - 1) * PER_PAGE)
      @users_data   = compute_user_data_for(paged_users)
      @page_owed    = @users_data.sum { |d| d[:owed] }
      @page_minted  = @users_data.sum { |d| d[:minted] }
      @has_next     = @page < @total_pages

      # HTML format → full page render (index.html.erb).
      # Turbo Stream format → index.turbo_stream.erb appends the new
      # rows into #users-tbody and replaces #load-trigger with the next
      # trigger (or removes it on the last page). The trigger has to
      # live OUTSIDE the table because the HTML parser will hoist a
      # turbo-frame out of <tbody>, breaking column alignment — see the
      # earlier turbo-frame attempt for the failure mode.
      respond_to do |format|
        format.html
        format.turbo_stream
      end
    end

    def mint
      user = User.find_by!(slug: params[:user_slug])
      rescue_and_log(target: user) do
        # OPSEC-030: serialize per-user. Double-click previously raced both
        # requests past compute_owed_for and both minted N tokens. The
        # on-chain sequence-collision check is still the source-of-truth
        # protection against actual double-mint, but the lock prevents the
        # wasted admin SOL rent on a doomed second instruction.
        user.with_lock do
          owed, levels = owed_plan_for(user)
          raise "Nothing owed to #{user.display_name}" if owed.zero?
          count = params[:count].present? ? params[:count].to_i : owed
          count = [count, owed].min
          signatures = mint_n_tokens(user, count, levels)
          flash[:notice] = "Minted #{signatures.length} free #{'entry'.pluralize(signatures.length)} for #{user.display_name}"
        end
      end
      redirect_to admin_free_entries_path
    end

    def mint_all
      rescue_and_log do
        users = users_with_wallet
        total = 0
        users.find_each do |user|
          owed, levels = owed_plan_for(user)
          next if owed.zero?
          mint_n_tokens(user, owed, levels)
          total += owed
        end
        flash[:notice] = "Minted #{total} free entries across all users"
      end
      redirect_to admin_free_entries_path
    end

    # Void a user's unspent free entries — the claw-back counterpart to #mint.
    # `count` burns that many (the row's "Burn 1"); absent, it burns every
    # unspent token the user holds (the row's "Burn all").
    #
    # There is deliberately NO #burn_all across ALL users to mirror #mint_all.
    # Minting too many costs the operator some SOL rent and a user gets a gift;
    # burning too many destroys property for every account on the platform at
    # once, and no support workflow needs it. The blast radius is capped at one
    # user on purpose.
    def burn
      user = User.find_by!(slug: params[:user_slug])
      rescue_and_log(target: user) do
        # Same per-user lock as #mint (OPSEC-030). Here it matters MORE: the
        # on-chain guard that makes minting safe to double-submit is `init`
        # collision, and burning has no equivalent — a second in-flight request
        # re-reads the same unspent list and aims at tokens the first is already
        # burning. Those lose the EntryTokenAlreadyBurned race noisily rather
        # than double-burning, but the lock keeps the operator from paying fees
        # to find that out.
        user.with_lock do
          burnable = burnable_tokens_for(user)

          # Not an exception: a stale row or a double-click lands here, and
          # neither is an incident worth an ErrorLog. Say so and move on.
          if burnable.empty?
            flash[:alert] = "No unspent free entries to burn for #{user.display_name}"
            next
          end

          count = params[:count].present? ? params[:count].to_i : burnable.length
          count = count.clamp(0, burnable.length)
          burned, failed = burn_n_tokens(user, burnable.first(count))

          # A total failure is a real incident — raise it so rescue_and_log files
          # an ErrorLog. A PARTIAL failure already did real work, so report the
          # true split instead of throwing away the record of what landed.
          raise "Burn failed for #{user.display_name}: #{failed.first}" if burned.empty? && failed.any?

          flash[:notice] = "Burned #{burned.length} free #{'entry'.pluralize(burned.length)} for #{user.display_name}"
          flash[:alert]  = "#{failed.length} burn(s) failed: #{failed.first}" if failed.any?
        end
      end
      redirect_to admin_free_entries_path
    end

    private

    def vault
      @vault ||= Solana::Vault.new
    end

    # User has no `solana_address` column — the schema splits it into
    # `web2_solana_address` (managed) and `web3_solana_address` (Phantom).
    # `User#solana_address` (method) returns web3 || web2.
    def users_with_wallet
      User.where(
        "(web3_solana_address IS NOT NULL AND web3_solana_address != '') OR " \
        "(web2_solana_address IS NOT NULL AND web2_solana_address != '')"
      )
    end

    # CACHE-FIRST render — issues NO Solana RPC on the render path. Copies the
    # navbar's pattern (ApplicationController#perform_solana_preload /
    # #display_entry_token_count): read Rails.cache only, render a "loading"
    # state on a cold cache, and let a background job warm the cache so the next
    # render is a hit.
    #
    # This page WAS the slowest local page (~869ms): the old version spawned two
    # live RPCs per user (sync_balance + list_entry_tokens) here, on the render
    # path — ~820ms of blocking network (Views=44ms, ActiveRecord=3ms). Threads
    # only capped wall time at the slowest single user; the real fix is to stop
    # reading on-chain on render at all.
    #
    #   - seeds/level come from the DENORMALIZED users.seeds mirror
    #     (User#update_level_from_seeds! keeps it fresh; the column's own
    #     comment names it "admin list display + sort"). No RPC, always present.
    #   - minted/unconsumed derive from the entry-token LIST read CACHE-FIRST via
    #     Solana::Vault.entry_tokens_cache_key — the SAME key the navbar reads,
    #     list_entry_tokens writes, and mint/consume invalidate. nil (cold) →
    #     the row renders a "syncing" loading state instead of a misleading 0.
    #
    # Accuracy: the counts shown are real prior on-chain reads (cached, at worst
    # ~60s stale), never wrong. And minting stays authoritative regardless of a
    # stale/cold display — #mint / #mint_all re-derive owed LIVE via
    # #compute_owed_for and clamp to it, so a cold navbar-style count can never
    # over-mint (the on-chain sequence-collision check is the final backstop).
    def compute_user_data_for(users_scope)
      users      = users_scope.to_a
      cold_users = []

      rows = users.map do |user|
        tokens  = cached_entry_tokens_for(user)  # Rails.cache.read only — nil when cold
        loading = tokens.nil?
        cold_users << user if loading
        tokens ||= []

        seeds      = user.seeds.to_i             # denormalized on-chain mirror — no RPC
        minted     = tokens.length
        unconsumed = tokens.count { |t| !t[:consumed] }
        owed       = loading ? 0 : [(seeds / SEEDS_PER_LEVEL) - minted, 0].max

        {
          user:       user,
          seeds:      seeds,
          level:      User.level_for(seeds),
          minted:     minted,
          unconsumed: unconsumed,
          owed:       owed,
          loading:    loading
        }
      end

      # Warm the cold users' on-chain reads OFF the render path so the next
      # render is a cache hit. Non-blocking; render already returned its values.
      warm_free_entries_cache(cold_users)

      rows.sort_by { |d| [-d[:owed], -d[:seeds]] }
    end

    # Cache-first entry-token list for a user. Reads the SAME key the navbar's
    # display_entry_token_count reads and list_entry_tokens / the refresh job
    # write (Solana::Vault.entry_tokens_cache_key). NO fetch-on-miss: a cold
    # cache returns nil ("loading"), never a synchronous getProgramAccounts scan
    # on the render path.
    def cached_entry_tokens_for(user)
      address = user.solana_address
      return nil if address.blank?

      Rails.cache.read(Solana::Vault.entry_tokens_cache_key(address))
    end

    # Enqueue ONE background refresh for the cold users, deduped by a short-lived
    # per-user guard so repeated page-nav within the cache TTL doesn't fan out
    # duplicate jobs. The job (Admin::FreeEntriesRefreshJob) does the blocking
    # sync_balance + list_entry_tokens reads and WRITES both caches off-request.
    def warm_free_entries_cache(cold_users)
      ids = cold_users.filter_map do |user|
        guard_key = "free_entries_refresh:#{user.id}"
        next if Rails.cache.read(guard_key)

        Rails.cache.write(guard_key, true, expires_in: REFRESH_GUARD_TTL)
        user.id
      end

      Admin::FreeEntriesRefreshJob.perform_later(ids) if ids.any?
    end

    def compute_owed_for(user)
      owed_plan_for(user).first
    end

    # The owed COUNT and the specific LEVELS behind it, from ONE pair of reads.
    #
    # The count is unchanged — the same arithmetic this page has always used, and
    # deliberately still ref-agnostic (`tokens.length`), so a hand-minted token
    # still suppresses an automatic grant. What is new is the second half: which
    # levels those are, so the mint below can key each token to its level exactly
    # as Tokens::LevelUpGrant does.
    def owed_plan_for(user)
      address = user.solana_address
      seeds   = (vault.sync_balance(address) rescue nil)&.dig(:seeds) || 0
      tokens  = (vault.list_entry_tokens(address) rescue [])
      owed    = [(seeds / SEEDS_PER_LEVEL) - tokens.length, 0].max

      [owed, Tokens::LevelUpGrant.missing_levels(address, seeds: seeds, tokens: tokens)]
    end

    # THE OPERATOR AND THE SWEEP MINT UNDER THE SAME REFS.
    #
    # A level this page is paying gets Tokens::LevelUpGrant's DETERMINISTIC ref, so
    # if the sweep is mid-flight for the same user and the same level, the second
    # instruction collides on `init` at an existing PDA and exactly one token
    # lands. That is the whole fix for the double-grant race: no lock, no
    # coordination, just one ref scheme instead of two.
    #
    # A mint with NO level behind it — `levels` short of `count`, which happens when
    # tokens exist that carry no level in their ref (older hand-mints, or refs
    # orphaned by a scheme change) — keeps the random operator ref. Those are
    # genuinely un-keyable, and inventing a level for one would key a token to a
    # milestone nobody reached.
    def mint_n_tokens(user, count, levels = [])
      address = user.solana_address

      Array.new(count) do |i|
        level = levels[i]
        source_ref = if level
                       Tokens::LevelUpGrant.source_ref(address, level)
        else
                       Solana::Vault.operator_source_ref(user)
        end

        vault.mint_entry_token(wallet_address: address, source: :operator,
                               source_ref: source_ref)[:signature]
      end
    end

    # The tokens a burn may target, NEWEST FIRST.
    #
    # LIVE read, not the render cache: #compute_user_data_for is deliberately
    # cache-first and up to ~60s stale, which is fine for displaying a count and
    # not fine for choosing which accounts to destroy. #mint re-derives live for
    # the same reason (#owed_plan_for).
    #
    # `consumed` is the only filter needed. A burn sets it, so already-burned
    # tokens fall out here as well as already-spent ones — the same one predicate
    # the on-chain guard uses.
    #
    # NEWEST FIRST because a partial burn is a claw-back of a RECENT mistake: an
    # operator who granted 3 by fat-finger and burns 1 means the one just
    # granted, not the token the user has been sitting on since signup. Oldest-
    # first would take the wrong one every time.
    def burnable_tokens_for(user)
      address = user.solana_address
      return [] if address.blank?

      (vault.list_entry_tokens(address) rescue [])
        .reject { |t| t[:consumed] }
        .sort_by { |t| -t[:created_at].to_i }
    end

    # Burn each token one instruction at a time, returning [burned, failures].
    #
    # Per-token rescue, unlike #mint_n_tokens: a mint that fails midway can be
    # re-run and the successful ones collide harmlessly on `init`, so aborting is
    # free. A burn is irreversible, so abandoning tokens 2 and 3 because token 1
    # hit an RPC flake leaves the operator guessing which ones actually went. The
    # caller decides what a partial result means.
    def burn_n_tokens(user, tokens)
      address  = user.solana_address
      burned   = []
      failures = []

      tokens.each do |token|
        vault.burn_entry_token(wallet_address: address, source_ref: token[:source_ref])
        burned << token[:pda]
        Rails.logger.info(
          "[free-entries] burned user=#{user.id} pda=#{token[:pda]} ref=#{token[:source_ref]}"
        )
      rescue => e
        failures << "#{e.class}: #{e.message.to_s[0, 140]}"
        Rails.logger.warn(
          "[free-entries] burn_failed user=#{user.id} pda=#{token[:pda]} " \
          "ref=#{token[:source_ref]} (#{e.class}: #{e.message.to_s[0, 140]})"
        )
      end

      # One bust after the batch, not one per token — every burn invalidated the
      # same key anyway, and the row must not render off a list that predates the
      # burns the operator just watched happen.
      user.bust_entry_tokens_cache! if burned.any?

      [burned, failures]
    end
  end
end
