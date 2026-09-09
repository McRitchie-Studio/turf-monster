class AdminController < ApplicationController
  before_action :require_admin, except: [:usdc_balance]



  def navbar
  end

  def level_badges
  end


  # SURVIVES ITS GALLERY, deliberately. /admin/modals was retired 2026-09-08 —
  # turf cards its own modals on /admin/style#host-modals now, against the real
  # partials. This action and layouts/modal_preview are kept ONLY as a render
  # seam for the test files that drive them and never touched the gallery
  # page. Nothing links here; it is not a review surface, and layouts/
  # modal_preview keeps a SECOND registration list which has drifted before
  # (it is why six gallery cards rendered empty for months). Retiring it is
  # /tasks/retire-the-preview-harness.
  def modal_preview
    @modal_id    = params[:modal_id].to_s
    @modal_props = params[:props].present? ? (JSON.parse(params[:props]) rescue {}) : {}
    render layout: "modal_preview"
  end

  # Legacy preview route from when the avatar cropper had its own
  # bespoke z-[110] overlay. Now that the cropper goes through the
  # shared modal host, this route is unused — keep it pointing at the
  # same minimal layout for back-compat with any bookmarked URL.
  def modal_preview_crop
    render layout: "modal_preview"
  end

  def hub
    @active_slate   = Slate.joins(:slate_matchups).distinct.order(created_at: :desc).first
    @latest_contest = Contest.order(created_at: :desc).first
  end

  # Read-only navbar-hydrate endpoint (NOT admin-gated — see the
  # `except: [:usdc_balance]` on require_admin). The client calls this on page
  # load and after on-chain successes to fill the navbar that now renders
  # cache-first (display_balance / display_seeds_data read Rails.cache only).
  #
  # One round-trip hydrates everything: USDC + USDT balances + seeds payload.
  # It fetches fresh (blocking is fine — runs after first paint), WARMS the
  # navbar caches (usdc/usdt/seeds), and returns them. `{ balance: }` is kept
  # for back-compat (refreshBalance reads data.balance). current_user only.
  def usdc_balance
    return render json: { error: "Not logged in" }, status: :unauthorized unless logged_in?
    return render json: { balance: 0, usdc: 0, usdt: 0, seeds: nil } unless current_user.solana_connected?

    hydrate = fetch_navbar_hydrate(current_user)
    seeds   = hydrate[:seeds]

    render json: {
      # Combined USDC + USDT (the navbar pill shows total spendable dollars —
      # see display_balance). null when BOTH reads flaked, so the client
      # leaves the prior pill value instead of painting a false $0.
      balance:     combined_balance(hydrate[:usdc], hydrate[:usdt]),
      # Per-currency values — feed $store.session.usdcCents/usdtCents and the
      # /account data-wallet-tile spans. null = unknown (RPC flake), the
      # client null-guards each field.
      usdc:        hydrate[:usdc],
      usdt:        hydrate[:usdt],
      # Entry-token count — same fetch that warms the navbar cache. Feeds the
      # /account data-wallet-tile="tokens" span via updateWalletTiles; null on
      # an RPC flake leaves the prior value. (This endpoint's refreshBalance
      # caller does not repaint the 🎟️ badge itself — page-load hydrate goes
      # through refreshSession — but returning it keeps the two endpoints
      # symmetric and warms the same cache.)
      tokens:      hydrate[:entry_token_count],
      seeds:       seeds,
      level:       (User.level_for(seeds) if seeds),
      toward_next: (User.seeds_toward_next_level(seeds) if seeds),
      progress:    (User.seeds_progress_percent(seeds) if seeds),
      seeds_to_next: (User::SEEDS_PER_LEVEL - User.seeds_toward_next_level(seeds) if seeds)
    }
  rescue => e
    Rails.logger.warn("[usdc_balance] hydrate failed: #{e.message}")
    render json: { balance: 0, usdc: 0, usdt: 0, seeds: nil }
  end

  def mint_usdc
    rescue_and_log(target: current_user) do
      raise "Admin mint is production-disabled" if AppFlags.live_production?  # OPSEC-020
      raise "Mint only available on Devnet" unless Solana::Config.devnet?

      vault = Solana::Vault.new
      admin = Solana::Keypair.admin

      vault.ensure_ata(admin.to_base58, mint: Solana::Config::USDC_MINT)
      amount = Solana::Config.dollars_to_lamports(500)
      result = vault.mint_spl(amount, mint: Solana::Config::USDC_MINT)

      invalidate_usdc_cache
      redirect_back fallback_location: root_path, notice: "Minted $500.00 USDC. TX: #{result[:signature]}"
    end
  rescue StandardError => e
    redirect_back fallback_location: root_path, alert: "Mint failed: #{e.message}"
  end
end
