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
          owed = compute_owed_for(user)
          raise "Nothing owed to #{user.display_name}" if owed.zero?
          count = params[:count].present? ? params[:count].to_i : owed
          count = [count, owed].min
          signatures = mint_n_tokens(user, count)
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
          owed = compute_owed_for(user)
          next if owed.zero?
          mint_n_tokens(user, owed)
          total += owed
        end
        flash[:notice] = "Minted #{total} free entries across all users"
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
      seeds = (vault.sync_balance(user.solana_address) rescue nil)&.dig(:seeds) || 0
      tokens = (vault.list_entry_tokens(user.solana_address) rescue [])
      [(seeds / SEEDS_PER_LEVEL) - tokens.length, 0].max
    end

    def mint_n_tokens(user, count)
      signatures = []
      count.times do
        # Globally-unique, <=64-byte source_ref per mint (the on-chain PDA is
        # sha256(source_ref), so a repeat collides on init). Centralized in
        # Solana::Vault.operator_source_ref — keyed on user.id + a random nonce;
        # see that method for why NOT the wallet address (it overflowed [u8;64]).
        result = vault.mint_entry_token(
          wallet_address: user.solana_address,
          source: :operator,
          source_ref: Solana::Vault.operator_source_ref(user)
        )
        signatures << result[:signature]
      end
      signatures
    end
  end
end
