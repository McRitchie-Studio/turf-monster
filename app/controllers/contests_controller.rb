class ContestsController < ApplicationController
  # Solana::SessionAuth is NOT included any more. Its one export is
  # verify_solana_signature!, and #enter's unreachable signature branch was this
  # controller's only caller. `onchain_session?` — still used all over this file
  # — comes from ApplicationController, not the concern, so the two are
  # unrelated despite reading alike.
  include DbSpanTracing

  skip_before_action :require_authentication, only: [:index, :show, :my, :world_cup, :leaderboard_poll, :live]
  # Observability for the latency tail (fix-turf-latency-tail): attribute the
  # DB wall time on the two hot paths — "/" (world_cup redirect) and the contest
  # show page — to connect vs execute. No-op-safe; DB_SPAN_TRACE=0 disables.
  around_action :trace_db_span, only: [:world_cup, :show]
  before_action :set_contest, only: [:show, :admin, :edit, :update, :update_banner, :toggle_selection, :enter, :check_funding, :clear_picks, :grade, :fill, :lock, :prepare_lock_time, :confirm_lock_time, :prepare_conclusion_time, :confirm_conclusion_time, :jump, :simulate_game, :simulate_batch, :reset, :close_onchain, :cancel_onchain, :prepare_entry, :discard_prepared_entry, :stamp_entry_signature, :recover_pending_entry, :confirm_onchain_entry, :prepare_onchain_contest, :confirm_onchain_contest, :leaderboard_poll, :live, :pick, :grade_round]
  before_action :require_admin, only: [:new, :create, :rebuild_create_tx, :finalize, :admin, :edit, :update, :update_banner, :generator, :generate_bundle, :finalize_bundle, :grade, :fill, :lock, :prepare_lock_time, :confirm_lock_time, :prepare_conclusion_time, :confirm_conclusion_time, :jump, :simulate_game, :simulate_batch, :reset, :close_onchain, :cancel_onchain, :prepare_onchain_contest, :confirm_onchain_contest, :grade_round]
  before_action :require_geo_allowed, only: [:toggle_selection, :enter, :prepare_entry]
  # B4 / OPSEC-048: frozen accounts can browse but cannot spend or enter.
  before_action :require_unfrozen_account, only: [:enter, :prepare_entry, :confirm_onchain_entry, :toggle_selection]

  def index
    @contests = Contest.where(status: [:open, :settled])
                       .includes(:slate).with_attached_contest_image
                       .order(created_at: :desc).to_a
    # One grouped query for confirmed entry counts — avoids a per-card / per-row
    # N+1 across the My Contests grid + All Contests table.
    @entry_counts = Entry.confirmed.where(contest_id: @contests.map(&:id)).group(:contest_id).count
    # "My Contests" = contests the viewer has entered. Filter the already-loaded
    # list in Ruby so there's no extra Contest query.
    @entered_contest_ids = (logged_in? ? current_user.entries.confirmed.distinct.pluck(:contest_id) : []).to_set
    @my_contests = @contests.select { |c| @entered_contest_ids.include?(c.id) }
  end

  def my
    @contests = Contest.where(status: [:open, :settled]).order(created_at: :desc)
    if logged_in?
      @my_entries = current_user.entries.confirmed.includes(:contest, selections: { slate_matchup: [:team, :opponent_team] }).group_by(&:contest_id)
    else
      @my_entries = {}
    end
  end

  def new
    # Pre-fill from query params (used by the contest generator matrix at /contests/generator).
    # Validates contest_type against FORMATS so an invalid query string can't poison the form.
    requested_type = params[:contest_type].presence
    contest_type = Contest.selectable_formats.key?(requested_type) ? requested_type : "medium"

    @contest = Contest.new(contest_type: contest_type)
    @slates_for_contest = contest_slate_options
    if params[:slate_id].present? && (prefilled_slate = Slate.find_by(id: params[:slate_id]))
      @contest.slate_id = prefilled_slate.id
      @default_sport = sport_for_slate(prefilled_slate)
    end
    @contest.slate ||= @slates_for_contest.first
    @contest.starts_at ||= default_start_for_slate(@contest.slate)
    @contest.season_id ||= SeasonConfig.current_season_id
    @season_options = onchain_season_options_for_form
  end

  # Admin matrix view: slates × contest types. Each cell shows how many
  # contests of that combo exist, and clicks through to /contests/new
  # pre-filled with that slate + tier. Makes it visually obvious which
  # slate/tier combinations are missing contests.
  def generator
    @slates = contest_slate_options
    @contest_counts = Contest.group(:slate_id, :contest_type).count   # → {[slate_id, "medium"] => 2, ...}
    @contests_by_cell = Contest.includes(:entries).order(created_at: :desc).group_by { |c| [c.slate_id, c.contest_type] }
  end

  # Phantom-driven provisioning of a curated contest + landing-page bundle.
  # Mirrors #create / #finalize: server builds a partially-signed create_contest
  # TX (admin pays rent, operator's Phantom signs the prize-pool USDC transfer),
  # client signs + broadcasts, then POST /contests/finalize_bundle persists the
  # Contest + LandingPage. Server-funded path (ContestBundle.generate!) needs
  # SOLANA_ADMIN_KEY and only runs locally / from Rails console.
  def generate_bundle
    return render_create_error("Phantom wallet required to provision bundles") unless current_user.phantom_wallet?
    return render_create_error("Unknown bundle: #{params[:key].inspect}") unless ContestBundle::ALL.key?(params[:key])

    contest = ContestBundle.build_unpersisted_contest(params[:key], current_user)
    if (err = onchain_create_precheck(contest, current_user))
      return render_create_error(err)
    end

    vault  = Solana::Vault.new
    result = vault.build_create_contest(
      current_user.web3_solana_address,
      contest.slug,
      **contest.onchain_params
    )

    render json: {
      success:       true,
      serialized_tx: result[:serialized_tx],
      contest_pda:   result[:contest_pda],
      slug:          contest.slug,
      params_token:  sign_bundle_payload(params[:key], contest, current_user)
    }
  rescue StandardError => e
    Rails.logger.error("[ContestsController#generate_bundle] #{e.class}: #{e.message}")
    capture_unlogged(e)
    render_create_error(e.message)
  end

  def finalize_bundle
    payload = verify_bundle_payload(params[:params_token])
    raise "User mismatch — token was issued to a different user" unless payload[:user_id] == current_user.id

    key = payload[:key]
    raise "Unknown bundle" unless ContestBundle::ALL.key?(key)

    vault = Solana::Vault.new
    ensure_onchain_season_ready!(payload[:season_id], vault: vault)

    derived_pda_b58 = Solana::Keypair.encode_base58(vault.contest_pda(payload[:slug]).first)
    raise "Contest PDA mismatch — slug=#{payload[:slug]}" unless params[:contest_pda] == derived_pda_b58

    verify_solana_transaction!(
      params[:tx_signature],
      instruction: "create_contest",
      signer: payload[:creator_pubkey],
      writable: derived_pda_b58
    )

    result = ContestBundle.finalize_phantom!(key, current_user, derived_pda_b58, params[:tx_signature],
                                             season_id: payload[:season_id])
    render json: {
      success:  true,
      redirect: generator_contests_path,
      contest:  contest_path(result[:contest]),
      landing:  landing_page_path(result[:landing_page])
    }
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    render_create_error("Invalid or expired bundle token — restart the provision flow.")
  rescue StandardError => e
    Rails.logger.error("[ContestsController#finalize_bundle] #{e.class}: #{e.message}")
    capture_unlogged(e)
    render_create_error(e.message)
  end

  # Phantom-driven contest creation:
  #
  #   step 1: POST /contests             → #create   — build unsigned TX, no DB write
  #   step 2: client signs in Phantom    → signed wire POSTed back, not broadcast
  #   step 3: POST /contests/finalize    → #finalize — validate, admin-cosign,
  #                                           simulate, broadcast, verify, save
  #
  # Form params get signed into a token in step 1 and echoed back in step 3
  # so the server doesn't have to trust the client's re-posted values.
  ONCHAIN_CREATE_TOKEN_KEY = :onchain_contest_create
  ONCHAIN_CREATE_TOKEN_TTL = 10.minutes

  def create
    return render_create_error("Phantom wallet required to create contests") unless current_user.phantom_wallet?

    contest = build_unpersisted_contest_from_params
    unless Contest.selectable_formats.key?(contest.contest_type)
      return render_create_error("Unknown or unavailable contest format")
    end
    # A requested span that could not be assembled (a gap, or a week with no
    # slate) must REFUSE, not fall back to a shorter contest — the on-chain fees
    # and prize pool are sized for the span the operator asked for.
    if @span_slate_error.present?
      return render_create_error(@span_slate_error)
    end
    # onchain_params falls back to `lock_timestamp: 0` when no start can be
    # resolved, which would put a contest on chain that never locks. Weekly NFL
    # slates carry no game times, so this is reachable from the form — refuse it
    # rather than mint an unlockable contest.
    if contest.turf_totals? && contest.starts_in_at.blank?
      return render_create_error("Set a lock time — the selected slate has no scheduled game times.")
    end
    if (err = onchain_create_precheck(contest, current_user))
      return render_create_error(err)
    end

    vault  = Solana::Vault.new
    result = vault.build_create_contest(
      current_user.web3_solana_address,
      contest.slug,
      **contest.onchain_params,
      admin_signs: false
    )

    render json: {
      success:       true,
      serialized_tx: result[:serialized_tx],
      contest_pda:   result[:contest_pda],
      slug:          contest.slug,
      params_token:  sign_onchain_create_payload(contest, current_user)
    }
  rescue StandardError => e
    Rails.logger.error("[ContestsController#create] #{e.class}: #{e.message}")
    capture_unlogged(e)
    render_create_error(e.message)
  end

  # Step 1.5 — re-issue the unsigned create_contest TX with a FRESH
  # blockhash immediately before the Phantom sign. The blockhash baked at
  # #create time goes stale while the user dwells in the wallet UI, which
  # surfaces as "Transaction simulation failed: Blockhash not found" /
  # silent send failures. The client calls this right before
  # provider.signTransaction so the TX that gets signed + broadcast carries
  # a current blockhash.
  #
  # The re-issue still goes through the server so the exact message bytes stay
  # bound to the signed params_token (no client-trusted form values).
  def rebuild_create_tx
    payload = verify_onchain_create_payload(params[:params_token])
    raise "User mismatch — token was issued to a different user" unless payload[:user_id] == current_user.id
    raise "Phantom wallet required to create contests" unless current_user.phantom_wallet?

    contest = build_contest_from_payload(payload)

    vault  = Solana::Vault.new
    ensure_onchain_season_ready!(contest.season_id, vault: vault)
    result = vault.build_create_contest(
      current_user.web3_solana_address,
      payload[:slug],
      **contest.onchain_params,
      admin_signs: false
    )

    render json: {
      success:       true,
      serialized_tx: result[:serialized_tx],
      contest_pda:   result[:contest_pda]
    }
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    render_create_error("Invalid or expired form token — restart the contest creation flow.")
  rescue StandardError => e
    Rails.logger.error("[ContestsController#rebuild_create_tx] #{e.class}: #{e.message}")
    capture_unlogged(e)
    render_create_error(e.message)
  end

  def finalize
    payload = verify_onchain_create_payload(params[:params_token])
    raise "User mismatch — token was issued to a different user" unless payload[:user_id] == current_user.id

    derived_pda_b58 = Solana::Keypair.encode_base58(Solana::Vault.new.contest_pda(payload[:slug]).first)
    raise "Contest PDA mismatch — slug=#{payload[:slug]}" unless params[:contest_pda] == derived_pda_b58
    raise "A contest with that slug already exists" if Contest.exists?(slug: payload[:slug])
    raise "Missing signed transaction" if params[:signed_tx].blank?

    contest = build_contest_from_payload(payload)
    vault = Solana::Vault.new
    ensure_onchain_season_ready!(contest.season_id, vault: vault)

    vault.assert_create_contest_cosign_safe!(
      params[:signed_tx],
      wallet_address: payload[:creator_pubkey],
      contest_slug: payload[:slug],
      onchain_params: contest.onchain_params
    )

    tx_signature = vault.cosign_and_broadcast_create_contest(params[:signed_tx])

    # OPSEC-010: assert the broadcast tx is the create_contest IX targeting
    # THIS PDA, signed by the original creator from the server-issued token.
    verify_solana_transaction!(
      tx_signature,
      instruction: "create_contest",
      signer: payload[:creator_pubkey],
      writable: derived_pda_b58
    )

    contest = build_finalized_contest(payload, derived_pda_b58, tx_signature)
    contest.contest_image.attach(params[:contest_image]) if params[:contest_image].present?
    contest.save!

    render json: { success: true, redirect: contest_path(contest), slug: contest.slug }
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    render_create_error("Invalid or expired form token — restart the contest creation flow.")
  rescue Solana::Vault::UnsafeCosignError => e
    Rails.logger.warn("[ContestsController#finalize] rejected create_contest cosign: #{e.message}")
    render_create_error("Signed transaction did not match this contest request. Rebuild the transaction and try again.")
  rescue StandardError => e
    Rails.logger.error("[ContestsController#finalize] #{e.class}: #{e.message}")
    capture_unlogged(e)
    render_create_error(e.message)
  end

  def edit
  end

  def update
    rescue_and_log(target: @contest) do
      @contest.update!(contest_update_params)
      # Mirror an edited lock time onto the chain (on-chain is master for
      # locking). nil starts_at sends 0 = clear the lock.
      if @contest.saved_change_to_starts_at? && @contest.onchain?
        Solana::Vault.new.set_contest_lock_time(@contest.slug, @contest.starts_at&.to_i || 0)
      end
      redirect_to root_path, notice: "Contest updated."
    end
  rescue StandardError => e
    render :edit, status: :unprocessable_entity
  end

  # Admin "Update banner" flow — swap just the contest's hero image. The admin
  # frames the image in the shared crop-photo modal (imageUploadHost +
  # cropPhotoModal, same cropper as the avatar) and the persistent uploader host
  # POSTs the cropped PNG here. Responds with a Turbo Stream that replaces
  # #contest-banner-preview on the edit screen. (A bad file 422s, but the crop
  # always yields a valid PNG, so that path is defensive — the picker has an
  # accept filter too.)
  def update_banner
    rescue_and_log(target: @contest) do
      file = params.dig(:contest, :contest_image)

      if valid_image?(file)
        @contest.contest_image.attach(file)
        respond_to do |format|
          # The crop modal saves immediately; refresh the preview on the edit
          # screen (the only caller). The contest show-page hero picks up the
          # new banner on its next full render.
          format.turbo_stream do
            render turbo_stream: turbo_stream.replace("contest-banner-preview", partial: "contests/banner_preview")
          end
          format.html { redirect_to edit_contest_path(@contest), notice: "Banner updated." }
        end
      else
        message = file.blank? ? "Choose an image to upload." : "Use a PNG, JPG, or WebP under 8 MB."
        redirect_to edit_contest_path(@contest), alert: message, status: :see_other
      end
    end
  end

  # Build a partially-signed create_contest transaction for Phantom co-signing.
  # Admin signs (pays rent), returns base64 tx for creator to co-sign client-side.
  def prepare_onchain_contest
    rescue_and_log(target: @contest) do
      raise "Already onchain" if @contest.onchain?
      raise "Phantom wallet required" unless current_user.phantom_wallet?

      vault = Solana::Vault.new
      result = vault.build_create_contest(
        current_user.web3_solana_address,
        @contest.slug,
        **@contest.onchain_params
      )

      render json: {
        success: true,
        serialized_tx: result[:serialized_tx],
        contest_slug: @contest.slug,
        contest_pda: result[:contest_pda]
      }
    end
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  # Confirm an onchain contest after the creator has co-signed and submitted the tx.
  def confirm_onchain_contest
    rescue_and_log(target: @contest) do
      raise "Already onchain" if @contest.onchain?

      # OPSEC-010: server-derive the contest PDA from the (already-known)
      # contest slug; refuse to trust params[:contest_pda] without checking.
      derived_pda_b58 = Solana::Keypair.encode_base58(Solana::Vault.new.contest_pda(@contest.slug).first)
      raise "Contest PDA mismatch" unless params[:contest_pda] == derived_pda_b58

      verify_solana_transaction!(
        params[:tx_signature],
        instruction: "create_contest",
        signer: current_user.web3_solana_address,
        writable: derived_pda_b58
      )

      @contest.update!(
        onchain_contest_id: derived_pda_b58,
        onchain_tx_signature: params[:tx_signature],
        # prepare_onchain_contest built the TX from onchain_params — the USDT
        # fee (entry_fee_by_currency slot 1) is funded on-chain.
        accepts_usdt: true
      )

      invalidate_usdc_cache if logged_in?

      render json: { success: true, tx: params[:tx_signature], pda: derived_pda_b58 }
    end
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  # Audit H2 (2026-05-23): `payout_entry` was removed.
  #
  # It was a per-entry admin button that called `vault.transfer_spl` from
  # admin's USDC ATA → user's ATA. Combined with `Contest#grade!` ->
  # `settle_onchain!` (which already transfers prize-pool USDC to winners via
  # the 2-of-3 settle_contest cosign flow), the two paths together produced a
  # **double payout**: settle pays the winner on-chain, then admin pays again.
  #
  # The single source of truth for payouts is now on-chain settle. After
  # cosign confirms, winners receive USDC in their own ATA. No admin per-entry
  # button.

  def world_cup
    @contest = Contest.featured
    return redirect_to contests_path unless @contest
    redirect_to contest_path(@contest)
  end

  def show
    @creator = @contest.user
    @has_entry = logged_in? && @contest.entries.where(user: current_user, status: [:active, :complete]).exists?
    @seeds_data = load_seeds_data
    # Quest card mission (username -> newsletter -> invite). Only for entered
    # users — the card is gated on @has_entry, so current_user is present.
    @quest_step = current_user.quest_step if @has_entry

    # Current user's entries on this contest — preloaded once so the contest
    # header (dropdown) and the "Your Entries" navigation card on the show
    # page don't re-query. Includes complete entries so the card still works
    # in settled state for read-only reference.
    @my_active_entries = if logged_in?
                           current_user.entries
                                       .where(contest: @contest, status: [:active, :complete])
                                       .includes(selections: { slate_matchup: [:team, :game] })
                                       .order(:entry_number, :id)
                                       .to_a
                         else
                           []
                         end

    # Resolve params[:edit_entry] → an active entry owned by current_user on
    # this contest. Picked up by the show template to swap the leaderboard
    # for the selection board in edit mode.
    if logged_in? && params[:edit_entry].present? && @contest.open?
      @edit_entry = @my_active_entries.find { |e| e.slug == params[:edit_entry] && e.active? }
    end

    load_contest_board_data

    # "More Contests" selector at the bottom of the page.
    @other_contests = Contest.where(status: [:open]).ranked.where.not(id: @contest.id).includes(:slate)

    if @contest.onchain?
      begin
        @onchain_contest = Solana::Vault.new.read_contest(@contest.slug)
      rescue => e
        Rails.logger.warn "Failed to read onchain contest: #{e.message}"
      end
    end
  end

  # Admin view of the contest show page — bypasses the "hide picks while
  # open" guard so operators can see every entry's selections for moderation.
  # Same render path as #show; @admin_view is the helper hook.
  def admin
    @admin_view = true
    show
    render :show
  end

  def leaderboard_poll
    version = params[:version].to_i
    current_version = @contest.updated_at.to_i

    if version == current_version
      render json: { changed: false }
    else
      load_contest_board_data
      partial = @contest.world_cup_survivor? ? "contests/world_cup_survivor_leaderboard" : "contests/turf_totals_leaderboard"
      html = render_to_string(partial: partial, locals: { compact: true, viewer: current_user })
      render json: { changed: true, version: current_version, html: html }
    end
  end

  # Live "active contest" page — real-time leaderboard + chat + games for an
  # in-progress contest, pushed over ActionCable (Contest::LiveBroadcast). New
  # dedicated route for now; we'll fold it into #show's live state later.
  # Turf Totals only for v1; Survivor + not-yet-live redirect to the show page.
  # The live board, reachable in EVERY contest state.
  #
  # It used to redirect unless `@contest.live?` — that is `locked? && !settled?`,
  # a window that excludes both halves an operator actually wants: before the
  # lock (watching an empty board fill as the games start) and after the settle
  # (reading the final result). During the first watched QA rehearsal the page
  # built for watching redirected for the ENTIRE watchable run, because the
  # contest was still open while its fixtures played.
  #
  # The NAV BUTTON stays conditional — there is no reason to point at a live
  # board for a contest with nothing happening — but the URL always resolves.
  # A link an operator has is a link that should work.
  def live
    return redirect_to contest_path(@contest) unless @contest.turf_totals?

    load_contest_board_data
    @games = @contest.games_by_phase
    @focus_slug = default_focus_game_slug(@games)
  end

  def enter
    # Cancelled contests are terminal — no new entries (the on-chain program
    # rejects enter_contest on a Cancelled Contest PDA; mirror it here so the
    # UI fails fast with a clear message).
    if @contest.cancelled?
      return render json: { success: false, error: "This contest was cancelled." },
                    status: :unprocessable_entity
    end

    return if render_age_gate_required

    # Web3-only onboarding (AppFlags.web3_only_onboarding?) — the AUTHORITATIVE
    # half of the client's 'wallet_setup_required' blocker. An account with no
    # wallet at all cannot be entered on-chain in ANY contest, free included,
    # so refuse here rather than fail deeper with an opaque Solana error. The
    # wallet_setup flag tells the client to reopen the setup modal.
    if current_user.wallet_kind == :none
      return render json: {
        success: false,
        error: "Connect a Solana wallet to enter — entries are signed on-chain.",
        wallet_setup: true
      }, status: :unprocessable_entity
    end

    # Self-custody guard (task #11 Stage 3). Runs FIRST so it catches
    # self-custodied users regardless of cart / contest state. The server
    # must not auto-sign for them; route to the Phantom-prepare path.
    # Clients catch this 422 + the self_custodied flag and walk the user
    # through Phantom sign-in if they aren't already in an onchain_session.
    if current_user.self_custodied?
      return render json: {
        success: false,
        error: "Your wallet is self-custodied. Sign in with Phantom (or your imported wallet) and re-enter — Turf Monster will not auto-sign for you.",
        self_custodied: true
      }, status: :unprocessable_entity
    end

    entry = @contest.entries.cart.find_by(user: current_user)
    # Survivor contests have no pick-building phase — entering creates the entry
    # directly. (Turf Totals' cart entry is created by toggle_selection.)
    entry ||= @contest.entries.find_or_create_by!(user: current_user, status: :cart) if @contest.world_cup_survivor?
    return redirect_to root_path, alert: "No cart entry found" unless entry

    # Attribute any RPC writes spawned by this action to the cart entry —
    # OutboundRequestLogger falls back to Current.outbound_source so future
    # audit-table hunts (cf. project_0xbc4_send_burst_2026_05_26) can trace
    # sendTransaction rows back to the specific entry instead of source:nil.
    Current.outbound_source = entry

    # #enter is the WEB2 / managed server-signing path — it funds the entry with
    # the custodial keypair. A web3 session does not belong here at all: it enters
    # through prepare_entry -> confirm_onchain_entry, where the on-chain tx the
    # wallet signs IS the ownership proof (the per-entry SIWS signMessage was
    # removed 2026-05-24 for exactly that reason).
    #
    # This REPLACES a signature-verification branch that no client could reach.
    # Both boards POST here with headers only and no body, so its
    # `params[:signature].present?` was never true. It was not merely dead — it
    # was a fail-CLOSED gate, so deleting it outright would have let a web3
    # session walk into the server-signing path with no check at all. Today that
    # still fails, but only incidentally: a phantom-only account has no
    # web2_solana_address, so resolve_web2_entry_funding! raises "Managed wallet
    # missing keypair" — an accident of another guard rather than a decision.
    #
    # So: refuse explicitly, and name the path the caller should be on. Same
    # shape as the self_custodied? guard above, which already routes rather than
    # merely refusing. The dead branch also consumed the SESSION NONCE if it ever
    # had fired (delete-before-verify), which would have broken a concurrent
    # login in another tab — one more reason not to leave it lying there.
    if onchain_session?
      return render json: {
        success: false,
        error: "Wallet sessions enter on-chain — use prepare_entry to build and sign the entry transaction.",
        self_custodied: true
      }, status: :unprocessable_entity
    end

    # Declared here so the durable-capture write + confirm! + respond_to below
    # (all OUTSIDE the with_lock transaction) can reference them. The on-chain
    # signature/PDA MUST outlive a confirm! failure — see the durable-capture
    # block after with_lock (incident 2026-06-08).
    token_consumed = false
    tx_signature = nil
    onchain_entry_id = nil

    rescue_and_log(target: entry, parent: @contest) do
      # DB-side gates (eligibility, season, on-chain backing) + entry-slot
      # reservation, serialized under the contest row lock. The IRREVERSIBLE
      # on-chain consume/transfer runs inside this block too — so EVERY
      # read-only eligibility gate (selection count, lock time, started games,
      # sybil, per-user limit, contest-full) MUST run BEFORE it (entry.
      # assert_enterable! below). Incident 2026-06-08: the consume ran first and
      # the gate-running confirm! raised AFTER the burn, stranding the user
      # (paid + entered on-chain, app showed `cart`). A reconciler can't heal a
      # genuine validation failure — re-running confirm! fails the same gate —
      # so the only correct fix is to validate BEFORE the irreversible side
      # effect (backend discipline #2). confirm! (hoisted out below) re-runs the
      # SAME assert_enterable! as its serialized backstop, and the durable
      # capture covers a TRANSIENT post-broadcast failure (RPC/DB), which the
      # reconciler then heals.
      @contest.with_lock do
        # PRE-FLIGHT: run the read-only eligibility gates BEFORE any consume.
        # Raises here → token stays unconsumed, entry stays `cart`, fail loudly.
        entry.assert_enterable!

        # On-chain entries require a configured season (seed_schedule lives on its PDA).
        # Catch the missing-season case early with a clear error instead of a cryptic
        # Anchor AccountNotInitialized further down.
        if @contest.onchain?
          current_sid = SeasonConfig.current_season_id
          raise "No active season configured. Set one at /admin/seasons before users can enter on-chain contests." if current_sid.to_i.zero?
        end

        # A paid contest must be backed by an on-chain Contest PDA — that PDA is
        # where the entry token / USDC payment is recorded. An off-chain paid
        # contest has no payment rail, so refuse rather than create a free entry.
        # (Entry#confirm! enforces the same gate as a model-level backstop.)
        if @contest.entry_fee_cents.to_i.positive? && !@contest.onchain?
          raise "This contest isn't on-chain yet — paid entry is unavailable."
        end

        if @contest.onchain? && @contest.entry_fee_cents > 0 && !onchain_session?
          # Web2 / managed-wallet (server-signed) entry funding. Unified priority
          # (operator spec 2026-06-13): entry token first, then USDC (flag-gated),
          # else block. web3 (Phantom) sessions never reach here — they fund via
          # prepare_entry / confirm_onchain_entry. See #resolve_web2_entry_funding!.
          tx_signature, onchain_entry_id, token_consumed = resolve_web2_entry_funding!(entry)
        end
      end

      # Durable capture (incident 2026-06-08). The on-chain consume/transfer
      # above is IRREVERSIBLE — the token is spent + the Entry PDA exists on
      # chain. Persist that proof onto the (still-`cart`) entry NOW, in a write
      # that has already left the with_lock transaction, so the gate-running
      # confirm! below can fail without erasing the fact that the user paid.
      # A strand is then a recoverable row (`cart` + onchain_tx_signature) that
      # self-heals via Entries::OnchainReconcileJob / `rake entries:reconcile_onchain`.
      entry.update!(onchain_tx_signature: tx_signature, onchain_entry_id: onchain_entry_id) if tx_signature

      finalize_managed_entry!(entry, tx_signature: tx_signature, onchain_entry_id: onchain_entry_id)

      # Announce the join in chat once — only when the entry actually went
      # active. A post-broadcast confirm failure (reconcile pending) skips this;
      # the reconciler announces when it heals the entry.
      announce_contest_join(entry) if entry.active?

      respond_to do |format|
        format.html { redirect_to contest_path(@contest), notice: "#{current_user.display_name} entered the contest!" }
        format.json {
          seeds = post_entry_seeds_payload(entry,
                                          path: "managed",
                                          tx_signature: entry.onchain_tx_signature,
                                          token_consumed: token_consumed)
          render json: {
            success: true,
            redirect: contest_path(@contest),
            tx_signature: entry.onchain_tx_signature,
            # Flag for the client: true iff this entry was paid for by
            # an on-chain EntryTokenAccount consumption. Drives the
            # navbar 🎟️ punch animation (animateFreeEntryBadge).
            token_consumed: token_consumed,
            **seeds
          }
        }
      end
    end
  rescue StandardError => e
    render_entry_error(e)
  end

  # Lightweight funding pre-check for the 2-second "Hold to Confirm" window
  # (2026-06-13). The client fires this the INSTANT the hold STARTS (without
  # awaiting) and acts on the resolved result when the hold COMPLETES (~2s
  # later): not-fundable → show the Top Up Wallet + abort the entry; fundable →
  # proceed with the existing confirm/entry. It does a FRESH, authoritative
  # balance read and NEVER touches the chain / enters.
  #
  # Why it exists: a fresh web2 (managed) wallet has no USDC ATA yet, so its
  # balance reads `null` client-side and slips past the hold-time
  # eligibilityBlocker (which fails OPEN on null) — so a $0 user would submit
  # and hit a doomed on-chain entry that fails with "custom program error: 0x1"
  # (SPL insufficient funds), a cryptic sim error instead of the Top Up Wallet.
  # This endpoint + the #resolve_web2_entry_funding! safety net close that gap.
  #
  # JSON contract: { fundable: bool, reason: "no_funding"|null,
  #                  method: "token"|"usdc"|"usdt"|null }. Fail-CLOSED — any read
  # failure returns { fundable: false, reason: "no_funding" } so the worst case
  # the user ever sees is the Top Up Wallet, never the 0x1 sim error.
  def check_funding
    # Token presence + balances must be authoritative for THIS check, so drop
    # the 60s entry-tokens cache first — a just-consumed token must not read as
    # still-available (#entry_funding_status reads balances fresh off-chain).
    # CONSCIOUS COUPLING (Avi review 2026-06-13): this also cold-busts the shared
    # navbar token-badge cache, forcing an extra getProgramAccounts on the next
    # navbar read. Accepted for authoritative freshness — the buy-flow's own
    # polling (waits for the token to confirm before returning to the board)
    # largely closes the Helius post-mint index-lag window; the check_funding/ip
    # throttle caps the getProgramAccounts amplification.
    current_user.bust_entry_tokens_cache!
    fundable, method = entry_funding_status
    render json: { fundable: fundable, reason: (fundable ? nil : "no_funding"), method: method }
  rescue StandardError => e
    # API path discipline: record to ErrorLog (capture_unlogged attaches the
    # @contest parent context, same as the stamp/recover endpoints), never raise
    # to the user, and fail CLOSED — the client hold then shows the Top Up Wallet.
    capture_unlogged(e, parent: @contest)
    render json: { fundable: false, reason: "no_funding", method: nil }
  end

  # Build an enter_contest transaction for Phantom users. Phantom signs first;
  # confirm_onchain_entry validates, admin-cosigns, broadcasts, and verifies.
  def prepare_entry
    if @contest.cancelled?
      return render json: { success: false, error: "This contest was cancelled." },
                    status: :unprocessable_entity
    end

    return if render_age_gate_required

    entry = @contest.entries.cart.find_by(user: current_user)
    # Survivor contests have no pick-building phase — see #enter.
    entry ||= @contest.entries.find_or_create_by!(user: current_user, status: :cart) if @contest.world_cup_survivor?
    return render json: { error: "No cart entry found" }, status: :unprocessable_entity unless entry

    Current.outbound_source = entry  # audit-log attribution; see #enter

    # Single-signature entry flow (2026-05-24): the per-entry SIWS
    # signMessage check was removed because the on-chain TX signed in
    # confirm_onchain_entry below is itself the wallet-ownership proof —
    # Anchor rejects any enter_contest whose signer doesn't match
    # the entry PDA's owner. We still require that this Rails session
    # was established via a Phantom signature at login (onchain_session?)
    # so a stolen email/password cookie can't pivot into the on-chain
    # entry flow.
    return render json: { success: false, error: "Phantom session required" }, status: :forbidden unless onchain_session?

    # Currency selection (2026-06-10): "usdc" (default, currency_idx 0) or
    # "usdt" (currency_idx 1). Strict allow-list — anything else is a client
    # bug. USDT only works on contests whose on-chain entry_fee_by_currency
    # funded slot 1 at creation (accepts_usdt) — older contests have an
    # immutable zero there and the program would reject with EntryFeeNotSet
    # (6027), so refuse up front with a clear error instead.
    currency = (params[:currency].presence || "usdc").to_s.downcase
    unless %w[usdc usdt].include?(currency)
      return render json: { success: false, error: "Unsupported currency #{params[:currency].to_s.inspect} — use \"usdc\" or \"usdt\"." },
                    status: :unprocessable_entity
    end
    if currency == "usdt" && !@contest.accepts_usdt?
      return render json: { success: false, error: "This contest doesn't accept USDT — enter with USDC instead." },
                    status: :unprocessable_entity
    end
    currency_idx = currency == "usdt" ? 1 : 0
    entry_mint   = currency_idx == 1 ? Solana::Config::USDT_MINT : Solana::Config::USDC_MINT

    rescue_and_log(target: entry, parent: @contest) do
      raise "Contest is not onchain" unless @contest.onchain?
      raise "Phantom wallet required" unless current_user.phantom_wallet?

      active_count = @contest.entries.where(status: [:active, :complete]).count
      raise "Contest is full" if @contest.max_entries && active_count >= @contest.max_entries

      # Validate selections
      raise "Exactly #{@contest.picks_required} selections required" unless entry.selections.count == @contest.picks_required
      entry.selections.includes(slate_matchup: :game).each do |s|
        raise "#{s.slate_matchup.team.name}'s game has already started" if s.slate_matchup.locked?
      end

      vault = Solana::Vault.new
      ensure_onchain_season_ready!(@contest.season_id, vault: vault)

      # Assign entry slot by probing the chain for a free index — guards against
      # the orphaned-PDA collision a contest Reset leaves behind (the System
      # `Allocate` "already in use" / 0x0 pre-flight failure). See
      # Entry#assign_onchain_entry_number!.
      entry.assign_onchain_entry_number!(current_user.web3_solana_address, vault)

      # Ensure user's onchain account exists and is current (auto-migrate if needed).
      # v0.16: username is required at PDA creation (validate_username on chain
      # enforces >= 3 chars). Pass current_user.username through.
      vault.ensure_user_account(current_user.web3_solana_address, username: current_user.username)

      # FUNDING PRIORITY — entry token first, then the currency transfer. Same
      # order the web2 path has used since the unified-funding spec (see
      # #resolve_web2_entry_funding!); until this task the Phantom path skipped
      # straight to the transfer, so a Phantom wallet holding a token was charged
      # USDC anyway and the token sat unspent.
      #
      # Scoped to the SIGNER address, not #solana_address, for the reason the web2
      # path scopes to its own: the wallet that signs the consume must OWN the
      # token or the program refuses it (owner != signer). Here they coincide —
      # Phantom signs and #web3_solana_address is what it signs as — and saying so
      # explicitly keeps that from becoming a silent coincidence.
      entry_token = current_user.next_unconsumed_entry_token_for(current_user.web3_solana_address)

      result =
        if entry_token
          # The token IS the payment: no SPL transfer, so no ATA is needed and
          # currency_idx carries no meaning on this wire.
          vault.build_enter_contest_with_token(
            current_user.web3_solana_address,
            @contest.slug,
            entry.entry_number,
            entry_token[:pda],
            season_id: @contest.season_id
          )
        else
          # v0.16: the user's ATA for the SELECTED currency must exist before they
          # can transfer from it. init_if_needed isn't used in the instruction so
          # we create it here (USDC for currency_idx 0, USDT for 1).
          vault.ensure_ata(current_user.web3_solana_address, mint: entry_mint)

          # v0.16 collapsed `enter_contest` + `enter_contest_direct` into a
          # single unified `enter_contest` instruction. currency_idx selects the
          # vault's accepted_currencies slot (0 = USDC, 1 = USDT) — validated
          # against @contest.accepts_usdt above.
          vault.build_enter_contest(
            current_user.web3_solana_address,
            @contest.slug,
            entry.entry_number,
            currency_idx: currency_idx,
            season_id: @contest.season_id
          )
        end

      # Persist a PendingTransaction so a refresh mid-flight (between Phantom's
      # sign and confirm_onchain_entry) leaves a server-side trail. In the
      # Phantom-FIRST flow (2026-06-05) broadcast is server-side, so the
      # signature + `confirmed` status are stamped in confirm_onchain_entry; this
      # row starts `pending` with no signature (nothing is broadcast until the
      # client returns Phantom's signed bytes to confirm_onchain_entry).
      ptx = PendingTransaction.create!(
        tx_type: "enter_contest",
        serialized_tx: result[:serialized_tx],
        status: "pending",
        target: entry,
        initiator_address: current_user.web3_solana_address,
        # entry_token_pda is the SERVER's record of what it prepared: the cosign
        # guard and the broadcast verification both read it back rather than
        # trusting the wire, so a client cannot present a token consume against
        # an entry we priced in USDC (or the reverse).
        metadata: { entry_pda: result[:entry_pda], contest_slug: @contest.slug, currency_idx: currency_idx,
                    funding: (entry_token ? "token" : "transfer"),
                    entry_token_pda: entry_token && entry_token[:pda] }.to_json
      )

      render json: {
        success: true,
        serialized_tx: result[:serialized_tx],
        entry_id: entry.id,
        entry_pda: result[:entry_pda],
        ptx_slug: ptx.slug,
        # Advisory for the client's copy only — the server decides the funding and
        # re-reads its own decision at confirm time.
        token_funded: entry_token.present?
      }
    end
  rescue StandardError => e
    render_entry_error(e)
  end

  # Retire an entry transaction that never received the user's wallet
  # signature. Phantom can dismiss or invalidate a pending request while the
  # page remains open; expiring that unsigned server record lets the client
  # prepare a fresh blockhash and retry in place. A row with a signature is
  # deliberately immutable here because it may already have been broadcast
  # and must go through recover_pending_entry instead.
  def discard_prepared_entry
    return render json: { error: "Missing ptx_slug" }, status: :unprocessable_entity if params[:ptx_slug].blank?

    ptx = PendingTransaction.find_by(slug: params[:ptx_slug], tx_type: "enter_contest", target_type: "Entry")
    return render json: { error: "Pending transaction not found" }, status: :not_found unless ptx

    entry = ptx.target
    authorized = current_user&.web3_solana_address.present? &&
      ptx.initiator_address.present? &&
      entry.is_a?(Entry) &&
      entry.contest_id == @contest.id &&
      entry.user_id == current_user&.id &&
      ptx.initiator_address == current_user&.web3_solana_address
    return render json: { error: "Not authorized" }, status: :forbidden unless authorized

    # The guard belongs in the WHERE, not in Ruby. Reading tx_signature here and
    # writing on the next line leaves a window: the signature broadcast can land
    # and stamp the row in between, and this would then expire a transaction that
    # actually SUCCEEDED — stranding a paid-for entry with no way back. Letting
    # the database re-check the same condition it is updating under closes it,
    # and the affected-row count IS the verdict: 1 means this request retired it,
    # 0 means someone else got there first, which is not an error.
    #
    # update_all skips validations and Sluggable's before_save by design — the
    # row already has its slug, and "expired" is a member of the status
    # inclusion list this bypasses.
    retired = PendingTransaction
      .where(id: ptx.id, status: %w[pending submitted], tx_signature: [nil, ""])
      .update_all(status: "expired", updated_at: Time.current) == 1

    render json: { retired: retired }
  rescue StandardError => e
    capture_unlogged(e, parent: @contest)
    render json: { retired: false, error: e.message }, status: :unprocessable_entity
  end

  # Stamp the on-chain signature onto the PendingTransaction created by
  # prepare_entry. Called by the client immediately after Phantom's
  # sendRawTransaction resolves and before connection.confirmTransaction —
  # so a refresh during the confirmation wait still has a server-side
  # signature trail. The endpoint is cheap (single UPDATE) and adds one
  # round-trip to the critical entry path.
  def stamp_entry_signature
    return render json: { error: "Missing ptx_slug or tx_signature" }, status: :unprocessable_entity if params[:ptx_slug].blank? || params[:tx_signature].blank?
    ptx = PendingTransaction.where(status: %w[pending submitted]).find_by(slug: params[:ptx_slug])
    return render json: { error: "Pending transaction not found" }, status: :not_found unless ptx
    # Don't allow stamping a PT that belongs to a different user — initiator
    # is the only authorization signal we have here.
    return render json: { error: "Not authorized" }, status: :forbidden unless ptx.initiator_address == current_user&.web3_solana_address
    ptx.update!(tx_signature: params[:tx_signature], status: "submitted")
    render json: { success: true }
  rescue StandardError => e
    capture_unlogged(e, parent: @contest)
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  # Resolve a PendingTransaction stranded by a mid-flight refresh. The
  # client polls this when the contest page loads with a pending/submitted
  # PT belonging to the current user. Three outcomes:
  #   - confirmed:  signature finalized on-chain → entry promoted to active,
  #                 PT marked confirmed, client redirects to the contest show page
  #   - processing: signature still unknown / propagating → client re-polls
  #                 after a short delay (handled by the board JS)
  #   - failed:     signature errored, never broadcast, or recovery threw
  #                 → PT marked failed, client closes modal and frees the
  #                 user to retry the entry flow
  def recover_pending_entry
    return render json: { error: "Missing ptx_slug" }, status: :unprocessable_entity if params[:ptx_slug].blank?
    ptx = PendingTransaction.where(status: %w[pending submitted]).find_by(slug: params[:ptx_slug])
    return render json: { status: "missing" } unless ptx
    return render json: { error: "Not authorized" }, status: :forbidden unless ptx.initiator_address == current_user&.web3_solana_address

    entry = ptx.target
    return render json: { error: "Invalid PT target" }, status: :unprocessable_entity unless entry.is_a?(Entry) && entry.contest_id == @contest.id
    # Defense-in-depth (Lazarus audit #1): the target entry must belong to the
    # caller. Today this is implied by the initiator_address check above plus
    # the fact that prepare_entry is the only enter_contest PT creator, but
    # asserting entry ownership explicitly keeps that invariant from becoming
    # silently load-bearing if another PT-creation path is ever added.
    return render json: { error: "Not authorized" }, status: :forbidden unless entry.user_id == current_user&.id
    prepared_token_pda = prepared_entry_token_pda(ptx)

    # Already-active entry → close the loop on the PT and short-circuit. The
    # activation can commit before the live path reaches its token-cache bust;
    # recovery therefore owes that invalidation too when the server record says
    # this attempt consumed a token. The bust is idempotent.
    if entry.active?
      ptx.update!(status: "confirmed")
      current_user.bust_entry_tokens_cache! if prepared_token_pda
      return render json: {
        status: "confirmed",
        redirect: contest_path(@contest),
        tx_signature: entry.onchain_tx_signature
      }
    end

    # No server-stamped signature scenario. In the Phantom-FIRST flow
    # (2026-06-05) broadcast is server-side INSIDE confirm_onchain_entry, and the
    # signature is stamped there IMMEDIATELY after broadcast, BEFORE verification
    # (A1). So a blank tx_signature here genuinely means broadcast never happened
    # — nothing landed on-chain — and it is SAFE to release the user to retry
    # (assign_onchain_entry_number! probes the chain for a free slot, so a retry
    # won't collide). A broadcast that SUCCEEDED but then failed verification
    # leaves a STAMPED PT (status "submitted", signature present), which skips this
    # branch and falls through to the RPC poll + verify_and_confirm below —
    # crediting the already-paid entry instead of re-charging the user.
    if ptx.tx_signature.blank?
      ptx.update!(status: "failed")
      return render json: { status: "failed", error: "Your last entry did not go through — try again." }
    end

    # Ask the RPC about the signature once. The client owns the polling
    # cadence; keeping this poll cheap (getSignatureStatuses) avoids tying up
    # a request thread while the TX propagates.
    vault = Solana::Vault.new
    status = vault.client.confirm_transaction(ptx.tx_signature).dig("value", 0)

    if status.nil?
      return render json: { status: "processing" }
    end

    if status["err"]
      ptx.update!(status: "failed")
      return render json: { status: "failed", error: "On-chain transaction failed." }
    end

    unless %w[confirmed finalized].include?(status["confirmationStatus"])
      return render json: { status: "processing" }
    end

    # TX landed. Run the SAME server-side verification the live path uses
    # before crediting — never trust ptx.metadata.entry_pda (client-supplied).
    # verify_and_confirm_onchain_entry! re-derives the PDA, asserts the
    # signature is a genuine enter_contest IX from this wallet, and activates
    # the entry; without it the recovery path would credit a paid entry from
    # ANY finalized signature. confirm_onchain! re-checks open/lock/limit/sybil
    # and the unique-signature index blocks replaying one tx across two rows.
    # (OPSEC-010 / Lazarus audit #1.)
    begin
      verify_and_confirm_onchain_entry!(entry, ptx.tx_signature,
                                        entry_token_pda: prepared_token_pda,
                                        vault: vault)
      ptx.update!(status: "confirmed")

      # Same consume, same stale cache: this path credits an entry whose token
      # was burned on-chain just as surely as the live path does, and it used to
      # bust nothing at all — so a user who crashed mid-entry came back to a
      # navbar badge and a "Hold for Free Entry" button still counting the token
      # they had already spent.
      current_user.bust_entry_tokens_cache! if prepared_token_pda

      render json: {
        status: "confirmed",
        redirect: contest_path(@contest),
        tx_signature: ptx.tx_signature
      }
    rescue StandardError => e
      capture_unlogged(e, target: entry, parent: @contest)
      ptx.update!(status: "failed")
      render json: { status: "failed", error: "Recovery failed: #{e.message}" }
    end
  rescue StandardError => e
    capture_unlogged(e, parent: @contest)
    render json: { status: "error", error: e.message }, status: :unprocessable_entity
  end

  # Confirm an onchain entry. Phantom-FIRST flow (2026-06-05): the client now
  # sends the Phantom-SIGNED-but-not-broadcast wire bytes (`signed_tx`, base64,
  # requireAllSignatures:false). The SERVER cosigns with the admin keypair
  # (Transaction.cosign_wire), runs a simulateTransaction pre-flight, broadcasts,
  # waits for confirmation, THEN runs the existing on-chain verification.
  #
  # Why the order flipped: when the server pre-signs and Phantom signs second,
  # Phantom's Lighthouse heuristics flag the multi-signer ordering ("could be
  # malicious"). Phantom signing the fully-unsigned tx first clears that rule.
  # Broadcast moving server-side means the server now owns + stamps the tx
  # signature (the client no longer calls stamp_entry_signature before confirm).
  def confirm_onchain_entry
    if @contest.cancelled?
      return render json: { success: false, error: "This contest was cancelled." },
                    status: :unprocessable_entity
    end

    entry = @contest.entries.find_by(id: params[:entry_id], user: current_user, status: :cart)
    return render json: { error: "Entry not found" }, status: :not_found unless entry

    Current.outbound_source = entry  # audit-log attribution; see #enter

    rescue_and_log(target: entry, parent: @contest) do
      raise "Wallet not linked" unless current_user.web3_solana_address.present?
      raise "Missing signed transaction" if params[:signed_tx].blank?

      # PRE-FLIGHT (backend discipline #2): run the read-only eligibility gates
      # BEFORE the irreversible cosign+broadcast below. The broadcast is
      # server-side here (cosign_and_broadcast_entry), so a gate failure must
      # raise NOW — nothing signed, nothing broadcast, entry stays `cart`. The
      # post-broadcast Entry#confirm_onchain! re-runs the SAME assert_enterable!
      # as its backstop (no drift); without this pre-flight a stale lock-time /
      # filled-contest / duplicate-combo between #prepare_entry and here would
      # only surface AFTER the on-chain payment moved (the 2026-06-08 ordering
      # bug, in the Phantom path).
      entry.assert_enterable!

      vault = Solana::Vault.new

      # What did the SERVER prepare — a token consume or a currency transfer?
      # Read it off the PendingTransaction #prepare_entry wrote, before anything
      # is cosigned. The lookup is hoisted above the cosign (it used to sit after
      # the broadcast, purely to stamp the signature) because the answer now gates
      # the cosign itself; the same row is stamped below, unchanged.
      ptx = PendingTransaction.where(target: entry, status: %w[pending submitted],
                                     initiator_address: current_user.web3_solana_address)
                              .order(:created_at).last
      prepared_token_pda = prepared_entry_token_pda(ptx)

      # Audit C1 (admin blind-cosign): SEMANTICALLY validate the Phantom-signed
      # wire BEFORE the admin signs anything. Decodes the client's tx and asserts
      # it is exactly the entry instruction we prepared — admin fee-payer, a single
      # enter_contest (or enter_contest_with_token, when that is what we built)
      # IX bound to THIS entry's PDA and to the token we chose, and only the
      # durable-nonce advance / ComputeBudget hints alongside. Raises Solana::Vault::
      # UnsafeCosignError (rescued below) on anything else, so a crafted
      # SystemProgram.transfer{from: admin} / mint_entry_token / grant_seeds never
      # reaches the cosign. Validate-then-cosign: NO cosign, NO broadcast on reject.
      vault.assert_entry_cosign_safe!(params[:signed_tx],
                                      entry: entry,
                                      wallet_address: current_user.web3_solana_address,
                                      entry_token_pda: prepared_token_pda)

      # Server-side: admin cosign (fills the empty admin slot in the
      # Phantom-signed wire tx) → simulateTransaction pre-flight → broadcast →
      # confirm. cosign_and_broadcast_entry re-asserts OPSEC-017 (fully signed)
      # and raises on a failed simulation before any broadcast.
      tx_signature = vault.cosign_and_broadcast_entry(params[:signed_tx])

      # A1 (double-charge guard): stamp the signature on the PendingTransaction
      # IMMEDIATELY after broadcast, BEFORE verification. The money has moved
      # on-chain at this point — if verify_and_confirm_onchain_entry! below raises
      # (e.g. a transient RPC error on getTransaction), the rescue must leave a PT
      # that CARRIES the signature so recover_pending_entry credits the already-
      # paid entry. A blank PT here would read as "never broadcast" and let the
      # user re-enter and pay twice (assign_onchain_entry_number! probes the chain
      # and would skip the already-paid PDA). The row was looked up above by
      # target+initiator (prepare_entry creates it pre-broadcast, before any
      # signature) because the cosign now reads the funding off it too.
      ptx&.update!(tx_signature: tx_signature, status: "submitted")

      # OPSEC-010 / Lazarus audit #1: server-derive the entry PDA, cross-check
      # the client-supplied one, assert the broadcast TX is the v0.16
      # enter_contest IX signed by the user's wallet writing to that PDA, then
      # activate. Shared with the crash-recovery path so neither can drift.
      verify_and_confirm_onchain_entry!(entry, tx_signature,
                                        expected_entry_pda: params[:entry_pda],
                                        entry_token_pda: prepared_token_pda,
                                        vault: vault)

      ptx&.update!(status: "confirmed")

      # The on-chain EntryTokenAccount.consumed flag just flipped. Drop the 60s
      # entry-tokens cache — BOTH layers, which is what #bust_entry_tokens_cache!
      # now does — so the navbar badge, the next hold-to-confirm label and a
      # follow-up entry all read the spent token as spent. The web2 path gets this
      # from Vault#enter_contest_with_token, which the Phantom path never reaches
      # (the consume rides the client's broadcast, not ours).
      current_user.bust_entry_tokens_cache! if prepared_token_pda

      # Confirmed (Phantom path, token or currency) — announce the join in chat once.
      announce_contest_join(entry)

      seeds = post_entry_seeds_payload(entry,
                                      path: "phantom-direct",
                                      tx_signature: tx_signature,
                                      token_consumed: prepared_token_pda.present?)
      render json: {
        success: true,
        redirect: contest_path(@contest),
        tx_signature: tx_signature,
        # Same flag the managed path returns: drives the navbar token punch
        # (animateFreeEntryBadge) when the entry was paid for with a token.
        token_consumed: prepared_token_pda.present?,
        **seeds
      }
    end
  rescue Solana::Vault::UnsafeCosignError
    # Audit C1: the submitted wire didn't match the entry we prepared, so the
    # admin never cosigned and nothing was broadcast. The detailed reason is
    # already logged server-side ([cosign][rejected] …) — return ONLY a generic,
    # non-revealing message + a stable `code` the frontend keys its retry UX off.
    render json: {
      success: false,
      code: "tx_rejected",
      error: "For your security we couldn't co-sign this transaction — it didn't match the entry we prepared. Please try again."
    }, status: :unprocessable_entity
  rescue StandardError => e
    render_entry_error(e)
  end

  def clear_picks
    entry = @contest.entries.cart.find_by(user: current_user)

    rescue_and_log(target: entry, parent: @contest) do
      if entry
        entry.update!(status: :abandoned)
      end

      respond_to do |format|
        format.html { redirect_to root_path, notice: "Picks cleared" }
        format.json { render json: { success: true } }
      end
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_to root_path, alert: e.message }
      format.json { render json: { success: false, error: e.message }, status: :unprocessable_entity }
    end
  end

  def toggle_selection
    unless @contest.open?
      return render json: { error: "Contest is not open" }, status: :unprocessable_entity
    end

    matchup = @contest.matchups.find_by(id: params[:matchup_id])
    return render json: { error: "Matchup not found" }, status: :not_found unless matchup

    entry = @contest.entries.find_or_create_by!(user: current_user, status: :cart)

    rescue_and_log(target: entry, parent: @contest) do
      selections_hash = entry.toggle_selection!(matchup)

      if selections_hash.nil?
        render json: { selections: {}, selection_count: 0 }
      else
        render json: { selections: selections_hash, selection_count: selections_hash.size }
      end
    end
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # World Cup Survivor — submit or replace this entry's pick for a round.
  def pick
    raise "Not a survivor contest" unless @contest.world_cup_survivor?

    round = params[:round_id].present? ? SurvivorRound.find_by(id: params[:round_id]) : SurvivorRound.current
    entry = @contest.entries.where(user: current_user, status: [:active, :complete]).first

    rescue_and_log(target: entry, parent: @contest) do
      raise "Enter the contest before making a pick" unless entry
      raise "You've been eliminated from this contest" if entry.eliminated?
      raise "Round not found" unless round
      raise "#{round.name} is locked" if round.picks_locked?

      team = Team.find_by(slug: params[:team_slug].to_s)
      raise "Team not found" unless team
      unless round.games.where("home_team_slug = :s OR away_team_slug = :s", s: team.slug).exists?
        raise "#{team.name} is not playing in #{round.name}"
      end
      if entry.survivor_picks.where(team_slug: team.slug).where.not(survivor_round_id: round.id).exists?
        raise "You've already used #{team.name} — no team can be picked twice"
      end

      pick = entry.survivor_picks.find_or_initialize_by(survivor_round: round)
      pick.team_slug = team.slug
      pick.save!

      render json: { success: true, round_id: round.id, team_slug: team.slug, team_name: team.name }
    end
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  def simulate_game
    rescue_and_log(target: @contest) do
      game = @contest.simulate_next_game!
      redirect_to @contest, notice: "Simulated #{game.home_team.name} vs #{game.away_team.name}: #{game.home_score}-#{game.away_score}"
    end
  rescue StandardError => e
    redirect_to @contest || root_path, alert: e.message
  end

  def grade
    rescue_and_log(target: @contest) do
      @contest.grade!

      respond_to do |format|
        format.html { redirect_to @contest, notice: "Contest graded and settled!" }
        format.json {
          render json: {
            success: true,
            redirect: contest_path(@contest),
            tx_signature: @contest.onchain_tx_signature
          }
        }
      end
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_to @contest || root_path, alert: e.message }
      format.json { render json: { success: false, error: e.message }, status: :unprocessable_entity }
    end
  end

  # World Cup Survivor — grade a round across every survivor entry (rounds are
  # global). Admin-only; the round's games must be final first.
  def grade_round
    rescue_and_log(target: @contest) do
      raise "Not a survivor contest" unless @contest.world_cup_survivor?
      round = params[:round_id].present? ? SurvivorRound.find_by(id: params[:round_id]) : SurvivorRound.current
      raise "No round to grade" unless round
      Survivor::GradeRound.call(round)
      redirect_to @contest, notice: "#{round.name} graded."
    end
  rescue StandardError => e
    redirect_to @contest || root_path, alert: e.message
  end

  def fill
    rescue_and_log(target: @contest) do
      @contest.fill!(users: User.where(email: [
        "alex@mcritchie.studio", "mason@mcritchie.studio",
        "mack@mcritchie.studio", "turf@mcritchie.studio"
      ]))
      redirect_to @contest, notice: "Contest filled with #{@contest.entries.where(status: [:active, :complete]).count} entries!"
    end
  rescue StandardError => e
    redirect_to @contest || root_path, alert: e.message
  end

  # Set the contest lock time (derived-lock model, v0.17). `in_seconds` defaults
  # to 0 = "lock now"; a positive value schedules a near-future lock (e.g. the
  # "Lock in 30s" testing button, to watch the countdown engage). On-chain is
  # master: flip the chain first (when on-chain), then mirror to starts_at so the
  # derived `locked?` + the page countdown agree.
  def lock
    rescue_and_log(target: @contest) do
      seconds = params[:in_seconds].to_i.clamp(0, 3600)
      lock_at = Time.current + seconds.seconds
      Solana::Vault.new.set_contest_lock_time(@contest.slug, lock_at.to_i) if @contest.onchain?
      @contest.update!(starts_at: lock_at)
      notice = seconds.positive? ? "Lock scheduled — entries close in #{seconds}s." : "Contest locked — entries closed."
      redirect_to @contest, notice: notice
    end
  rescue StandardError => e
    redirect_to @contest || root_path, alert: e.message
  end

  # Phantom-prepared lock (web3). set_contest_lock_time is 1-of-3 and the admin's
  # Phantom is a vault signer, so a single Phantom signature authorizes it.
  # prepare_lock_time builds the TX (bot pays the fee, Phantom signs the admin
  # slot); the client signs + broadcasts; confirm_lock_time verifies on-chain
  # then mirrors starts_at (chain is master — DB only moves post-confirm).
  def prepare_lock_time
    return render json: { success: false, error: "Phantom session required" }, status: :forbidden unless onchain_session?

    rescue_and_log(target: @contest) do
      raise "Contest is not onchain" unless @contest.onchain?
      raise "Phantom wallet required" unless current_user.phantom_wallet?
      raise "Contest already concluded — lock time can't change" if @contest.settled?

      seconds = params[:in_seconds].to_i.clamp(0, 3600)
      lock_at = Time.current + seconds.seconds

      result = Solana::Vault.new.build_set_contest_lock_time(
        @contest.slug, lock_at.to_i, admin_pubkey: current_user.web3_solana_address
      )

      render json: { success: true, serialized_tx: result[:serialized_tx], lock_timestamp: lock_at.to_i }
    end
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  def confirm_lock_time
    rescue_and_log(target: @contest) do
      raise "Wallet not linked" unless current_user.web3_solana_address.present?
      lock_ts = params[:lock_timestamp].to_i
      raise "Missing lock timestamp" unless lock_ts.positive?

      contest_pda_b58 = Solana::Keypair.encode_base58(
        Solana::Vault.new.contest_pda(@contest.slug).first
      )
      verify_solana_transaction!(
        params[:tx_signature],
        instruction: "set_contest_lock_time",
        signer: current_user.web3_solana_address,
        writable: contest_pda_b58
      )

      # Chain is master — mirror starts_at only after the on-chain TX confirms.
      @contest.update!(starts_at: Time.at(lock_ts))

      render json: { success: true, redirect: contest_path(@contest), locks_at: @contest.locks_at&.iso8601 }
    end
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  # Phantom-prepared conclusion (web3), parallel to prepare/confirm_lock_time.
  # Sets the on-chain conclusion timestamp; after it passes, the lock time is
  # final (set_contest_lock_time rejects). Mirrors starts_at handling.
  def prepare_conclusion_time
    return render json: { success: false, error: "Phantom session required" }, status: :forbidden unless onchain_session?

    rescue_and_log(target: @contest) do
      raise "Contest is not onchain" unless @contest.onchain?
      raise "Phantom wallet required" unless current_user.phantom_wallet?
      raise "Contest already concluded — conclusion time can't change" if @contest.concluded?

      seconds = params[:in_seconds].to_i.clamp(0, 604_800) # up to a week out
      conclude_at = Time.current + seconds.seconds

      result = Solana::Vault.new.build_set_contest_conclusion_time(
        @contest.slug, conclude_at.to_i, admin_pubkey: current_user.web3_solana_address
      )

      render json: { success: true, serialized_tx: result[:serialized_tx], conclusion_timestamp: conclude_at.to_i }
    end
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  def confirm_conclusion_time
    rescue_and_log(target: @contest) do
      raise "Wallet not linked" unless current_user.web3_solana_address.present?
      ts = params[:conclusion_timestamp].to_i
      raise "Missing conclusion timestamp" unless ts.positive?

      contest_pda_b58 = Solana::Keypair.encode_base58(
        Solana::Vault.new.contest_pda(@contest.slug).first
      )
      verify_solana_transaction!(
        params[:tx_signature],
        instruction: "set_contest_conclusion_time",
        signer: current_user.web3_solana_address,
        writable: contest_pda_b58
      )

      # Chain is master — mirror concludes_at only after the on-chain TX confirms.
      @contest.update!(concludes_at: Time.at(ts))

      render json: { success: true, redirect: contest_path(@contest), concludes_at: @contest.concludes_at&.iso8601 }
    end
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  def jump
    rescue_and_log(target: @contest) do
      @contest.jump!
      redirect_to @contest, notice: "Contest jumped! Results simulated and settled."
    end
  rescue StandardError => e
    redirect_to @contest || root_path, alert: e.message
  end

  def reset
    rescue_and_log(target: @contest) do
      @contest.reset!
      redirect_to root_path, notice: "Contest reset!"
    end
  rescue StandardError => e
    redirect_to root_path, alert: e.message
  end

  def simulate_batch
    count = params[:count].to_i
    count = 5 if count <= 0

    rescue_and_log(target: @contest) do
      simulated = @contest.simulate_games!(count)
      redirect_to @contest, notice: "Simulated #{simulated} game(s)."
    end
  rescue StandardError => e
    redirect_to @contest || root_path, alert: e.message
  end

  # Reclaim on-chain rent (close_contest, 1-of-3 server-signed). The program
  # only allows close once the Contest PDA is in a terminal state (Settled or
  # Cancelled — error 6005 otherwise), so we gate on the same. Single vault
  # signer = the bot's admin keypair signs + broadcasts itself; no
  # PendingTransaction / cosign needed.
  def close_onchain
    rescue_and_log(target: @contest) do
      raise "Contest must be settled or cancelled before closing on-chain" unless @contest.settled? || @contest.onchain_cancelled?
      raise "Contest is already closed on-chain" if @contest.onchain_closed?

      result = Solana::Vault.new.close_contest(@contest.slug)
      @contest.update!(onchain_closed: true)
      redirect_to @contest, notice: "On-chain rent reclaimed (close_contest: #{result[:signature]})."
    end
  rescue StandardError => e
    redirect_to @contest || root_path, alert: e.message
  end

  # Cancel an open contest + refund the creator's prize pool (cancel_contest,
  # 2-of-3). Builds a partially-signed TX and queues it for cosign in the
  # Treasury (mirrors Contest#settle_onchain!). The creator MUST be the
  # authoritative on-chain creator — the program constrains
  # creator_token_account.authority == contest.creator — so read it off-chain
  # rather than trusting contest.user.solana_address.
  def cancel_onchain
    rescue_and_log(target: @contest) do
      raise "Contest is not on-chain" unless @contest.onchain?
      raise "Only open contests can be cancelled" unless @contest.open?
      raise "Contest is already cancelled" if @contest.onchain_cancelled?

      vault = Solana::Vault.new
      onchain = vault.read_contest(@contest.slug)
      raise "Could not read on-chain contest" unless onchain
      creator_pubkey = onchain[:creator]
      raise "On-chain creator unavailable" if creator_pubkey.blank?

      result = vault.build_cancel_contest(
        @contest.slug,
        creator_pubkey: creator_pubkey,
        cosigner_pubkey: Solana::Config::MULTISIG_COSIGNER
      )

      PendingTransaction.create!(
        tx_type: "cancel_contest",
        serialized_tx: result[:serialized_tx],
        target: @contest,
        initiator_address: Solana::Keypair.admin.to_base58,
        metadata: { creator: creator_pubkey }.to_json
      )

      redirect_to admin_pending_transactions_path,
        notice: "Cancel queued for cosign — refunds #{creator_pubkey[0..7]}… in the Treasury."
    end
  rescue StandardError => e
    redirect_to @contest || root_path, alert: e.message
  end

  private

  # Entry-time age gate (ENABLE_AGE_GATE). When the gate is on and this user
  # hasn't verified their DOB, refuse the entry BEFORE any payment and hand the
  # client an `age_required` blocker so its hold-to-confirm flow pops the DOB
  # modal (ahead of the Get Entry Tokens / balance modal). Returns true when it
  # rendered a block (caller `return if render_age_gate_required`), false to
  # let the entry proceed. AgeVerificationsController is the only writer; this
  # is the authoritative server-side guard.
  def render_age_gate_required
    return false unless age_verification_pending?

    render json: {
      success: false,
      age_required: true,
      blocker: { reason: "age_required" },
      error: "Please verify your age before entering."
    }, status: :unprocessable_entity
    true
  end

  # Build the post-confirm seeds payload for the entry-confirm JSON responses
  # in #enter (managed wallet) and #confirm_onchain_entry (Phantom direct).
  # Reads the seeds awarded for this entry's number off-chain (Season schedule
  # mirror) plus the user's current lifetime seeds via sync_balance, derives
  # the level, then handles the post-confirm fanout housekeeping:
  #
  #   1. `Rails.logger.info "[entry][confirmed] path=… seeds_earned=… …"` so
  #      production debugging has a grep-able trail (pair with the
  #      `[state-fanout][seeds]` console line on the client).
  #   2. invalidate_seeds_cache + invalidate_usdc_cache so the next page
  #      render sees fresh chain state without waiting for the 60s TTL.
  #
  # Returns `{ seeds_earned:, seeds_total:, seeds_level: }` for splat into
  # the JSON response.
  # Post the "🎉 <name> joined the contest" announcement to the contest chat
  # on a user's FIRST confirmed entry. Idempotent (Message.announce_join! is a
  # no-op for an already-announced user) so re-confirms / the 3-entries-per-user
  # allowance never double-post, and chat-disabled contests get nothing. The
  # Message's after_create_commit broadcast handles real-time delivery — no new
  # cable plumbing here. Best-effort: a chat hiccup must not fail the entry that
  # already confirmed (Message.announce_join! rescues internally).
  def announce_contest_join(entry)
    return unless entry&.user
    Message.announce_join!(contest: @contest, user: entry.user)
  end

  # Flip the cart entry to `active` now that payment has settled (on-chain
  # consume/transfer done, or a free contest). For an on-chain-paid entry whose
  # proof we already durably captured, a confirm! failure must NOT strand the
  # user or invite a double-spend retry: the token/USDC is already gone on chain
  # and the Entry PDA exists, so the entry IS valid — we schedule the reconciler
  # to converge the Rails row to active out-of-band and let the success response
  # stand (the durable onchain_tx_signature keeps the row recoverable). A free /
  # off-chain entry has nothing to recover, so its confirm! failure re-raises as
  # a normal error. (Incident 2026-06-08.)
  # Web2 / managed-wallet entry funding — runs INSIDE #enter's @contest.with_lock
  # (after entry.assert_enterable!) for a non-onchain session on a paid on-chain
  # contest. Unified funding priority (operator spec 2026-06-13):
  #   1. ENTRY TOKEN (incl. seed-earned free entries) — atomic on-chain consume
  #      via enter_contest_with_token (no USDC transfer; token IS the payment).
  #   2. USDC, only when ENABLE_WEB2_USDC_ENTRY is on — the server signs the
  #      existing enter_contest (USDC) instruction with the managed keypair
  #      (Solana::Vault#enter_contest_with_usdc). This is what lets a USDC
  #      contest payout fund the next entry.
  #   3. else block ("No entry tokens") — flag-off token-only fallback (today's
  #      behavior). Solana::ErrorInterpreter maps the raise to the no_funding
  #      blocker so the board opens the Top Up Wallet modal.
  # USDT is deliberately NOT offered to web2 (payouts are USDC).
  #
  # Everything derives from the managed (web2) address so a managed+phantom
  # combo account signs with — and spends from — the custodial wallet the server
  # holds, never the web3 address (which #solana_address would otherwise prefer
  # and desync from the keypair). Returns [tx_signature, onchain_entry_id,
  # token_consumed]; the IRREVERSIBLE consume/transfer is durably captured by
  # the caller immediately after with_lock (incident 2026-06-08).
  def resolve_web2_entry_funding!(entry)
    address = current_user.web2_solana_address
    raise "Managed wallet missing keypair (cannot sign entry)" if address.blank?

    vault = Solana::Vault.new
    # Probe the chain for a free entry slot (handles orphaned PDAs left by a
    # contest Reset). See Entry#assign_onchain_entry_number!.
    entry.assign_onchain_entry_number!(address, vault)

    # Token detection MUST be scoped to the SAME web2 `address` we sign with.
    # #next_unconsumed_entry_token reads #solana_address (web3-preferred for a
    # combo account), so for a managed+phantom account it would surface a
    # web3-OWNED token the managed keypair can't consume (doomed owner != signer)
    # AND mask an available USDC fallback — a confusing hard wall. Scoping to the
    # web2 address makes the token sub-path derive from the same wallet the USDC
    # sub-path's signer guard already pins. (Avi review 2026-06-13.)
    token = current_user.next_unconsumed_entry_token_for(address)
    if token
      vault.ensure_user_account(address, username: current_user.username) if current_user.solana_connected?
      # OPSEC-004: the token owner (managed keypair) must sign the consume.
      result = vault.enter_contest_with_token(
        address, @contest.slug, entry.entry_number, token[:pda],
        user_keypair: current_user.solana_keypair, season_id: @contest.season_id
      )
      # The on-chain EntryTokenAccount.consumed flag just flipped to true. Bust
      # the 60s entry-tokens cache so a follow-up entry within the same TTL
      # doesn't re-pick this token and trip 0x177f (EntryTokenAlreadyConsumed).
      current_user.bust_entry_tokens_cache!
      [result[:signature], result[:entry_pda], true]
    elsif AppFlags.web2_usdc_entry?
      # SAFETY NET (2026-06-13): pre-check the USDC balance BEFORE the
      # irreversible on-chain enter. A fresh managed wallet with no USDC ATA
      # reads `null` client-side, slips past the hold-time eligibilityBlocker
      # (which fails OPEN on null), and would otherwise attempt a doomed SPL
      # transfer that fails with "custom program error: 0x1" (insufficient
      # funds) — a cryptic sim error, not the Top Up Wallet. Validate before the
      # side effect (backend discipline #2): underfunded → raise no_funding
      # (Solana::ErrorInterpreter maps "not enough usdc" + web2 mode to the
      # no_funding/web2 blocker → board opens the Top Up Wallet), never broadcast
      # a doomed entry. FRESH authoritative read — the 60s navbar cache is not
      # trusted here.
      #
      # FAIL-OPEN ON A READ FAILURE (Avi review 2026-06-13): read with
      # raise_on_read_error so a transient getTokenAccountsByOwner flake RAISES
      # rather than masquerading as $0 — a confirmed-zero must block, but a
      # FLAKED read must NOT false-block a funded user (whose atomic SPL transfer
      # would have succeeded). On a read failure, fall through to the atomic
      # enter and let it be the authority: it succeeds for a funded wallet, and
      # fails 0x1 for a genuine $0 — which ErrorInterpreter ALREADY backstops to
      # no_funding/web2 (Top Up Wallet). Only a CONFIRMED-insufficient balance
      # raises the pre-check no_funding here.
      fee_cents = @contest.entry_fee_cents.to_i
      begin
        usdc_cents = dollars_to_cents(vault.fetch_wallet_balances(address, raise_on_read_error: true)[:usdc])
        if usdc_cents < fee_cents
          raise "Not enough USDC to enter this contest — top up your wallet and try again."
        end
      rescue Solana::Client::RpcError
        # Balance read flaked — defer to the self-protecting atomic enter below.
      end

      # enter_contest_with_usdc encapsulates the web2-address/keypair/username
      # resolution + ensure_user_account + ensure_ata(USDC) preamble, so the
      # signer/ATA-desync footgun can't reach the call site. Atomic SPL transfer
      # + entry-PDA init — an underfunded ATA fails the whole TX (no strand).
      result = vault.enter_contest_with_usdc(
        user: current_user, contest: @contest, entry_num: entry.entry_number
      )
      [result[:signature], result[:entry_pda], false]
    else
      raise "No entry tokens. Buy at /tokens/buy"
    end
  end

  # Authoritative funding capability for #check_funding — returns
  # [fundable_bool, method] where method is "token" | "usdc" | "usdt" | nil.
  # Mirrors the entry funding priority (#resolve_web2_entry_funding! for web2,
  # #prepare_entry for web3): entry token first, then USDC, then — web3 only —
  # USDT. Reads BALANCES FRESH off-chain (Solana::Vault#fetch_wallet_balances is
  # always a live RPC; the 60s navbar cache is deliberately NOT trusted here),
  # and the token read is fresh too (the caller busts the entry-tokens cache).
  #   - SIGNER address: web3 (Phantom) session funds from web3_solana_address;
  #     web2 / managed funds from web2_solana_address (the SAME address the
  #     server signs the entry with — see #resolve_web2_entry_funding!).
  #   - USDC: web3 always; web2 only behind the ENABLE_WEB2_USDC_ENTRY flag.
  #   - USDT: web3 only, and only on an accepts_usdt contest (web2 never holds
  #     USDT — payouts are USDC).
  def entry_funding_status
    fee_cents = @contest.entry_fee_cents.to_i
    return [true, nil] if fee_cents <= 0 # free contest — nothing to fund

    web3    = onchain_session?
    address = web3 ? current_user.web3_solana_address : current_user.web2_solana_address
    return [false, nil] if address.blank?

    # 1. Entry token (incl. seed-earned free entries), scoped to the SIGNER addr.
    return [true, "token"] if current_user.next_unconsumed_entry_token_for(address).present?

    # USDC is a funding path for web3 always; for web2 only behind the flag.
    usdc_fundable = web3 || AppFlags.web2_usdc_entry?

    # FRESH authoritative balance read — never the 60s cache. FAIL-OPEN ON A READ
    # FAILURE (Avi review 2026-06-13): read with raise_on_read_error so a
    # transient getTokenAccountsByOwner flake RAISES rather than masquerading as
    # $0. On a read failure, fail OPEN whenever a balance funding path is even
    # possible — false-blocking a funded user is the regression; the atomic
    # on-chain enter is the self-protecting authority (it succeeds for a funded
    # wallet, 0x1-then-Top-Up for a genuine $0). When NO balance path exists
    # (web2 with the flag off and no token), there is nothing to fail open TO, so
    # stay not-fundable.
    begin
      balances = Solana::Vault.new.fetch_wallet_balances(address, raise_on_read_error: true)
    rescue Solana::Client::RpcError
      return [usdc_fundable, nil]
    end
    usdc_cents = dollars_to_cents(balances[:usdc])
    usdt_cents = dollars_to_cents(balances[:usdt])

    # 2. USDC — web3 always; web2 only behind the kill-switch flag.
    return [true, "usdc"] if usdc_fundable && usdc_cents >= fee_cents

    # 3. USDT — web3 only, contest must accept it on-chain.
    return [true, "usdt"] if web3 && @contest.accepts_usdt? && usdt_cents >= fee_cents

    [false, nil]
  end

  # uiAmount dollars (Float | Integer | nil from #fetch_wallet_balances) →
  # integer cents. BigDecimal so on-chain money is never compared through float
  # drift; nil (mint unconfigured / no ATA) → 0, and we FLOOR — both fail closed
  # so a missing or sub-cent balance can never read as enough to fund.
  def dollars_to_cents(dollars)
    return 0 if dollars.nil?
    (BigDecimal(dollars.to_s) * 100).floor
  end

  def finalize_managed_entry!(entry, tx_signature:, onchain_entry_id:)
    entry.confirm!(tx_signature: tx_signature, onchain_entry_id: onchain_entry_id)
  rescue StandardError => e
    raise e if tx_signature.blank?

    Rails.logger.error(
      "[entry][post-broadcast-confirm-failed] entry_id=#{entry.id} " \
      "contest=#{@contest.slug} user_id=#{entry.user_id} " \
      "tx=#{tx_signature.to_s.first(8)}... #{e.class}: #{e.message} — " \
      "scheduling reconcile (token already consumed on-chain)"
    )

    # This branch SWALLOWS the exception (the on-chain payment already settled, so
    # the entry is valid and reconciles out-of-band) — which means the outer
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

  def post_entry_seeds_payload(entry, path:, tx_signature:, token_consumed: nil)
    seeds_earned = 0
    seeds_total  = 0
    seeds_level  = 0
    verified_seeds_total = nil

    if entry.onchain_tx_signature.present? && entry.entry_number.present?
      begin
        seeds_earned = Solana::Vault.new.seeds_for_entry(entry.entry_number)
      rescue => e
        Rails.logger.warn "Failed to read seeds_for_entry: #{e.message}"
      end
      if current_user.solana_connected?
        begin
          onchain = Solana::Vault.new.sync_balance(current_user.solana_address)
          verified_seeds_total = onchain&.dig(:seeds)
          seeds_total = verified_seeds_total || 0
        rescue => e
          Rails.logger.warn "Failed to read seeds after entry: #{e.message}"
        end
      end
      seeds_level = User.level_for(seeds_total)
      LevelUpTokenMintJob.nudge(current_user, seeds_total: verified_seeds_total) if verified_seeds_total
    end

    tx_prefix = tx_signature.to_s.first(8)
    token_part = token_consumed.nil? ? "" : " token_consumed=#{token_consumed}"
    Rails.logger.info(
      "[entry][confirmed] path=#{path} user_id=#{current_user.id} " \
      "entry_id=#{entry.id} contest=#{@contest.slug} tx=#{tx_prefix}... " \
      "seeds_earned=#{seeds_earned} seeds_total=#{seeds_total} " \
      "seeds_level=#{seeds_level}#{token_part}"
    )

    if current_user.solana_connected?
      invalidate_seeds_cache
      invalidate_usdc_cache
    end

    { seeds_earned: seeds_earned, seeds_total: seeds_total, seeds_level: seeds_level }
  end

  # Renders the JSON error response for every entry-flow endpoint (enter,
  # prepare_entry, confirm_onchain_entry). Runs the raw exception through
  # Solana::ErrorInterpreter so the client gets a structured `blocker` it
  # can route through the same showEligibilityBlockerModal dispatcher the
  # preflight check uses. When the interpreter flags log:true (currently
  # 0xbbb / AccountDidNotDeserialize — IDL drift signal), the exception is
  # escalated to Rails.logger.error so ops sees it; rescue_and_log has
  # already persisted an error_logs row with the full backtrace.
  def render_entry_error(exception)
    # rescue_and_log persists an error_logs row for any fault raised INSIDE its
    # block (and sets @_error_logged). But the entry endpoints (enter,
    # prepare_entry, confirm_onchain_entry) do guard/auth work BEFORE that block
    # — a fault there would reach here unlogged. capture_unlogged closes that gap
    # without double-logging the rescue_and_log path. (Operator directive: every
    # endpoint records failures to ErrorLog.)
    capture_unlogged(exception, parent: @contest)

    # Thread the viewer's wallet mode so a web2/managed USDC entry that 6002s
    # on-chain (underfunded ATA) routes to the no_funding/web2 Top Up modal, not
    # the web3 deposit/currency picker. web3 (Phantom) sessions stay unchanged.
    result = Solana::ErrorInterpreter.interpret(exception, contest: @contest, mode: wallet_context.mode)
    Rails.logger.error("[entry][escalate] #{exception.class}: #{exception.message}") if result[:log]

    if request.format.json?
      render json: { success: false, error: result[:message], blocker: result[:blocker] },
             status: :unprocessable_entity
    else
      redirect_to root_path, alert: result[:message]
    end
  end

  # ── Phantom contest-create helpers ─────────────────────────────────────────

  def render_create_error(msg)
    render json: { success: false, error: msg }, status: :unprocessable_entity
  end

  # Persist an ErrorLog for an exception rescued OUTSIDE rescue_and_log (the
  # create/finalize flows, the entry-flow pre-block guards, the stamp/recover
  # endpoints) so every endpoint's failures land in ErrorLog per the operator
  # directive. No-op when rescue_and_log already logged this request
  # (@_error_logged) so we never double-log. Attaches optional target/parent
  # context (using slugs, matching rescue_and_log). The caller still renders /
  # raises as before — this only records.
  def capture_unlogged(exception, target: nil, parent: nil)
    return if @_error_logged

    log = create_error_log(exception)
    if target
      log.target = target
      log.target_name = target.slug
    end
    if parent
      log.parent = parent
      log.parent_name = parent.slug
    end
    log.save! if target || parent
    @_error_logged = true
    log
  end

  def build_unpersisted_contest_from_params
    Contest.new(contest_params).tap do |c|
      config = c.format_config
      c.entry_fee_cents = config[:entry_fee_cents]
      c.max_entries     = config[:max_entries]
      c.status          = :open
      # A multi-week contest is played on ONE span slate holding every week's
      # games. Resolving it here means slate_id stays a plain scalar FK and the
      # frozen per-team turf_score on that slate is what prices and settles.
      span = resolve_span_slate(c)
      c.slate_id = span.id if span
      c.starts_at       ||= default_start_for_slate(c.slate)
      c.season_id       ||= SeasonConfig.current_season_id
    end
  end

  # Resolve the operator's "N weeks from this anchor" into the ONE span slate the
  # contest is played on, building it if it doesn't exist yet.
  #
  # Nfl::BuildSpanSlate RAISES on a gap or a missing week rather than returning a
  # shorter span. That matters: a silently-truncated span was minted on-chain
  # with three-week fees and a three-week prize pool, then scored as one week.
  # `span_slate_error` carries the message so #create can refuse.
  #
  # A span of 1 returns nil, leaving the plain slate_id select untouched.
  def resolve_span_slate(contest)
    span = params.dig(:contest, :week_span).to_i
    return nil if span <= 1

    anchor = Slate.find_by(id: params.dig(:contest, :slate_id)) || contest.slate
    return nil if anchor.nil? || anchor.week.blank?

    # The COLUMN, via Slate#season_year, not a name regex. This is the entry point to
    # the span lookup `slates-sport-year` converted to columns, so parsing the name here
    # would leave the rename half-done — and the old `/\b(\d{4})\b/` was unbounded, so a
    # slate named "Week 1234" read as year 1234. #season_year is bounded to 20xx and
    # falls back to the name only when the column is null.
    year = anchor.season_year || Time.current.year
    weeks = (anchor.week...(anchor.week + span)).to_a

    Nfl::BuildSpanSlate.call(year: year, weeks: weeks)
  rescue Nfl::BuildSpanSlate::Error => e
    @span_slate_error = e.message
    nil
  end

  # Reconstruct an unpersisted Contest from the signed create payload so its
  # #onchain_params reproduce the exact instruction data #create built (fees,
  # max_entries, payouts, prize_pool, lock_timestamp). Used by #rebuild_create_tx
  # to re-issue the TX over a fresh blockhash without trusting client values.
  def build_contest_from_payload(payload)
    Contest.new(
      name:         payload[:name],
      slug:         payload[:slug],
      slate_id:     payload[:slate_id],
      contest_type: payload[:contest_type],
      starts_at:    payload[:starts_at],
      entry_fee_cents: payload[:entry_fee_cents],
      max_entries:     payload[:max_entries],
      status:          :open,
      season_id:       payload[:season_id]
    )
  end

  def build_finalized_contest(payload, derived_pda_b58, tx_signature)
    Contest.new(
      name:                       payload[:name],
      slug:                       payload[:slug],
      slate_id:                   payload[:slate_id],
      contest_type:               payload[:contest_type],
      starts_at:                  payload[:starts_at],
      locks_at_date_selected:     payload[:locks_at_date_selected],
      locks_at_time_selected:     payload[:locks_at_time_selected],
      locks_at_timezone_selected: payload[:locks_at_timezone_selected],
      entry_fee_cents:            payload[:entry_fee_cents],
      max_entries:                payload[:max_entries],
      status:                     :open,
      user:                       current_user,
      onchain_contest_id:         derived_pda_b58,
      onchain_tx_signature:       tx_signature,
      season_id:                  payload[:season_id],
      # The create_contest TX just verified was built from onchain_params,
      # which funds entry_fee_by_currency slot 1 (USDT) alongside slot 0.
      accepts_usdt:               true
    ).tap { |c| c.skip_onchain_callback = true }
  end

  # Returns nil if it's safe to proceed, or an error message string explaining
  # why we should refuse to build a TX. The on-chain checks (PDA existence,
  # wallet USDC balance) make round-trips to devnet, so order them last.
  def onchain_create_precheck(contest, creator)
    # Slug is the manual, globally-unique key — it seeds the on-chain PDA
    # (contest_id = sha256(slug)). Validate the model first so a malformed slug
    # (spaces/uppercase/symbols, > 64 bytes, name > 96 bytes) is rejected before
    # we burn an RPC round-trip or a Phantom signature.
    contest.validate
    if (slug_errors = contest.errors[:slug]).any?
      return "Slug #{slug_errors.first}"
    end
    if (name_errors = contest.errors[:name]).any?
      return "Name #{name_errors.first}"
    end

    slug = contest.slug
    return "Slug is required" if slug.blank?
    return "A contest with that slug already exists" if Contest.exists?(slug: slug)

    vault   = Solana::Vault.new
    pda_b58 = Solana::Keypair.encode_base58(vault.contest_pda(slug).first)
    if vault.client.get_account_info(pda_b58)&.dig("value")
      # Catches the "stranded contest" case where a prior finalize attempt
      # failed AFTER the on-chain TX succeeded. Anchor's `init` constraint
      # would reject a re-mint anyway — fail loudly here instead of letting
      # the user waste a Phantom signature.
      return "On-chain Contest PDA #{pda_b58.first(8)}… already exists for this slug. Pick a different slug."
    end

    if (season_error = onchain_season_error(contest.season_id, vault: vault))
      return season_error
    end

    insufficient_usdc_error(contest, creator, vault)
  end

  def ensure_onchain_season_ready!(season_id, vault:)
    if (error = onchain_season_error(season_id, vault: vault))
      raise error
    end
  end

  def onchain_season_error(season_id, vault:)
    sid = season_id.to_i
    return "No active season configured. Set one at /admin/seasons before creating on-chain contests." if sid.zero?

    season = vault.get_season(sid)
    return nil if season.present? && season[:season_id].to_i == sid
    if season.present?
      return "Season #{sid} returned on-chain season #{season[:season_id].inspect}. Set a valid season at /admin/seasons before creating on-chain contests."
    end

    "Season #{sid} is not initialized on-chain. Set a valid season at /admin/seasons before creating on-chain contests."
  rescue StandardError => e
    Rails.logger.warn(
      "[ContestsController#onchain_season_error] season_id=#{sid} unreadable " \
      "error=#{e.class}: #{e.message}"
    )
    "Season #{sid} is not readable on-chain. Set a valid season at /admin/seasons before creating on-chain contests."
  end

  def onchain_season_options_for_form
    seasons = Array(Solana::Vault.new.list_seasons)
    return seasons if seasons.any?

    current_id = SeasonConfig.current_season_id.to_i
    current_id.positive? ? [{ season_id: current_id, name: "Season #{current_id}" }] : []
  rescue StandardError => e
    Rails.logger.warn(
      "[ContestsController#onchain_season_options_for_form] failed " \
      "error=#{e.class}: #{e.message}"
    )
    current_id = SeasonConfig.current_season_id.to_i
    current_id.positive? ? [{ season_id: current_id, name: "Season #{current_id}" }] : []
  end

  def insufficient_usdc_error(contest, creator, vault)
    prize_cents = contest.guaranteed_prize_cents
    return nil unless prize_cents.positive?

    ata_b58 = Solana::Keypair.encode_base58(
      Solana::SplToken.find_associated_token_address(creator.web3_solana_address, Solana::Config::USDC_MINT).first
    )

    # FRESH read for the create decision — never the 60s-cached display_balance.
    # A nil/failed read (RPC flake, ATA-not-found edge) is NOT treated as a
    # pass and is NOT silently coerced to $0; it's a HARD BLOCK so a doomed TX
    # can't slip through on a transient read failure. We capture the raw read
    # exception separately from a legitimately-empty-but-readable ATA.
    read_error  = nil
    balance_info = begin
      vault.client.get_token_account_balance(ata_b58)
    rescue StandardError => e
      read_error = e
      nil
    end

    if read_error || balance_info.nil?
      Rails.logger.warn(
        "[ContestsController#insufficient_usdc_error] USDC balance read FAILED " \
        "ata=#{ata_b58} user=#{creator.id} prize_cents=#{prize_cents} " \
        "error=#{read_error&.class}: #{read_error&.message}"
      )
      return "We couldn't verify your USDC balance right now — please try again in a moment."
    end

    balance_cents = (balance_info.dig("value", "uiAmount").to_f * 100).round
    Rails.logger.info(
      "[ContestsController#insufficient_usdc_error] USDC balance read " \
      "ata=#{ata_b58} user=#{creator.id} balance_cents=#{balance_cents} prize_cents=#{prize_cents}"
    )
    return nil if balance_cents >= prize_cents

    "Insufficient USDC: prize pool needs $#{format('%.2f', prize_cents / 100.0)}, " \
      "your wallet has $#{format('%.2f', balance_cents / 100.0)}. " \
      "Top up or pick a smaller tier."
  end

  # Signed payload used to round-trip form params from #create → Phantom → #finalize
  # without trusting the client's re-posted values. JSON serialization downgrades
  # symbol keys to strings — #verify wraps the result in HashWithIndifferentAccess.
  def sign_onchain_create_payload(contest, creator)
    payload = {
      slug:                       contest.slug,
      name:                       contest.name,
      slate_id:                   contest.slate_id,
      contest_type:               contest.contest_type,
      starts_at:                  contest.starts_at&.iso8601,
      locks_at_date_selected:     contest.locks_at_date_selected,
      locks_at_time_selected:     contest.locks_at_time_selected,
      locks_at_timezone_selected: contest.locks_at_timezone_selected,
      entry_fee_cents:            contest.entry_fee_cents,
      max_entries:                contest.max_entries,
      season_id:                  contest.season_id,
      user_id:                    creator.id,
      creator_pubkey:             creator.web3_solana_address
    }
    Rails.application.message_verifier(ONCHAIN_CREATE_TOKEN_KEY)
         .generate(payload, expires_in: ONCHAIN_CREATE_TOKEN_TTL)
  end

  def verify_onchain_create_payload(token)
    Rails.application.message_verifier(ONCHAIN_CREATE_TOKEN_KEY)
         .verify(token)
         .with_indifferent_access
  end

  ONCHAIN_BUNDLE_TOKEN_KEY = :onchain_contest_bundle
  ONCHAIN_BUNDLE_TOKEN_TTL = 10.minutes

  # Bundle token is narrower than the generic create token — the bundle
  # `key` selects the full spec server-side from ContestBundle::ALL, so the
  # token only needs to bind (key, slug, user, pubkey) to the issued TX.
  def sign_bundle_payload(key, contest, creator)
    Rails.application.message_verifier(ONCHAIN_BUNDLE_TOKEN_KEY)
         .generate({
           key:            key,
           slug:           contest.slug,
           season_id:      contest.season_id,
           user_id:        creator.id,
           creator_pubkey: creator.web3_solana_address
         }, expires_in: ONCHAIN_BUNDLE_TOKEN_TTL)
  end

  def verify_bundle_payload(token)
    Rails.application.message_verifier(ONCHAIN_BUNDLE_TOKEN_KEY)
         .verify(token)
         .with_indifferent_access
  end

  # ── End Phantom contest-create helpers ─────────────────────────────────────

  # OPSEC-010: semantic verification of a confirmed Solana transaction.
  # Delegates to Solana::TxVerifier, which fetches the TX from chain and
  # asserts the instruction is the one we expected (program ID + Anchor
  # discriminator + optional signer + optional writable PDA). Prevents
  # `params[:tx_signature]` from being any successful TX the attacker has
  # ever seen — it has to be the create_contest/enter/settle/etc. for the
  # expected contest/entry/pubkey.
  #
  # `instruction:` is required; `signer:` and `writable:` are optional but
  # every production caller should pass both.
  def verify_solana_transaction!(signature, instruction:, signer: nil, writable: nil)
    Solana::TxVerifier.verify!(
      signature: signature,
      instruction_name: instruction,
      signer_pubkey: signer,
      writable_pubkey: writable
    )
  rescue Solana::TxVerifier::VerificationError => e
    raise e.message
  end

  # Shared on-chain entry confirmation, used by BOTH the live confirm path
  # (#confirm_onchain_entry) and the crash-recovery path (#recover_pending_entry).
  # Server-DERIVES the entry PDA from (contest slug, the session wallet, this
  # entry's entry_number) — never trusts a client-supplied PDA — asserts the
  # signature is a genuine `enter_contest` IX signed by this user and writing
  # to that derived PDA (OPSEC-010 / Lazarus audit #1), then activates the
  # entry. Keeping both callers on this one method stops the recovery path
  # from ever drifting back to the unverified-signature critical it just
  # closed. Returns the server-derived entry PDA (base58).
  #
  # `expected_entry_pda:` — the live path passes the client-supplied PDA to
  #   cross-check (mismatch raises, matching the prior inline guard); the
  #   recovery path omits it (default `false` = skip the cross-check) since it
  #   has no trustworthy client PDA — re-deriving is the whole point. A real
  #   PDA is always a non-empty base58 string, so `false` is an unambiguous
  #   "not provided" sentinel.
  # `entry_token_pda:` — the EntryTokenAccount #prepare_entry chose for this
  #   entry, read back from the PendingTransaction (never the client). Present
  #   means the broadcast must prove an `enter_contest_with_token`; absent, the
  #   `enter_contest` transfer. Verifying the WRONG instruction name would accept
  #   a signature that never moved the funding this entry was priced with.
  # `vault:` — lets a caller reuse an already-instantiated Solana::Vault.
  # The EntryTokenAccount #prepare_entry recorded for this attempt, or nil when it
  # prepared a currency transfer. The PendingTransaction is the server's own note
  # to itself, so this is the one trustworthy answer to "what funding did we
  # price this entry with" at cosign / verify / recover time. A row from before
  # this task carries no `funding` key at all, and reads nil — the USDC path,
  # which is exactly what those attempts were.
  # SHAPE NOTE: `metadata` is a jsonb column that every writer here fills with
  # `.to_json`, so Postgres holds a JSON *string* scalar and reads come back as a
  # String, not a Hash (this is why PendingTransaction#parsed_metadata parses at
  # all). Accept both rather than betting on one — a row written as a real object
  # would otherwise raise TypeError inside the entry's confirm path.
  def prepared_entry_token_pda(ptx)
    return nil if ptx.nil? || ptx.metadata.blank?

    meta = ptx.metadata
    meta = JSON.parse(meta) if meta.is_a?(String)
    return nil unless meta.is_a?(Hash)

    meta["entry_token_pda"].presence
  rescue JSON::ParserError => e
    Rails.logger.warn("[entry] unparseable PendingTransaction metadata ptx=#{ptx&.id}: #{e.message}")
    nil
  end

  def verify_and_confirm_onchain_entry!(entry, tx_signature, expected_entry_pda: false,
                                        entry_token_pda: nil, vault: Solana::Vault.new)
    derived_entry_pda = Solana::Keypair.encode_base58(
      vault.entry_pda(@contest.slug, current_user.web3_solana_address, entry.entry_number).first
    )
    raise "Entry PDA mismatch" if expected_entry_pda != false && expected_entry_pda != derived_entry_pda

    verify_solana_transaction!(
      tx_signature,
      instruction: entry_token_pda.present? ? "enter_contest_with_token" : "enter_contest",
      signer: current_user.web3_solana_address,
      writable: derived_entry_pda
    )

    entry.confirm_onchain!(tx_signature: tx_signature, entry_pda: derived_entry_pda)
    derived_entry_pda
  end

  def set_contest
    @contest = Contest.find_by(slug: params[:id])
    return if @contest

    # Diagnostic — every "Contest not found" toast in the wild traces back
    # to this miss. Log enough forensics to identify the source: who, what
    # slug, what path, where they came from, browser vs Turbo, user-agent.
    # `grep '\[set_contest:miss\]' log/development.log` after the toast
    # appears to inspect.
    Rails.logger.warn(
      "[set_contest:miss] " \
      "slug=#{params[:id].inspect} " \
      "method=#{request.method} " \
      "path=#{request.fullpath.inspect} " \
      "referer=#{request.referer.inspect} " \
      "turbo_frame=#{request.headers['Turbo-Frame'].inspect} " \
      "xhr=#{request.xhr?} " \
      "format=#{request.format.to_s.inspect} " \
      "user=#{logged_in? ? current_user.id : 'guest'} " \
      "ua=#{request.user_agent.to_s.first(120).inspect}"
    )

    respond_to do |format|
      format.html { redirect_to root_path, alert: "Contest not found" }
      format.json { render json: { error: "Contest not found" }, status: :not_found }
    end
  end

  def load_contest_board_data
    return load_survivor_board_data if @contest.world_cup_survivor?

    if @contest.locked? || @contest.settled?
      cache_key = "contest/#{@contest.slug}/v#{@contest.updated_at.to_i}/show_data"
      cached = Rails.cache.fetch(cache_key, expires_in: 1.hour) do
        {
          matchups: @contest.matchups.ranked.includes(:team, :opponent_team, :game).to_a,
          entries: @contest.entries.where(status: [:active, :complete]).includes(:user, selections: { slate_matchup: [:team, :game] }).order(score: :desc).to_a
        }
      end
      @matchups = cached[:matchups]
      @entries = cached[:entries]
    else
      @matchups = @contest.matchups.ranked.includes(:team, :opponent_team, :game)
      @entries = @contest.entries.where(status: [:active, :complete]).includes(:user, selections: { slate_matchup: [:team, :game] }).order(score: :desc)
    end
    @cart_entry = @contest.entries.cart.find_by(user: current_user) if logged_in?
    @pending_recovery_ptx = find_pending_recovery_ptx
  end

  # Which game the live page opens on: whatever is being played, else whatever
  # is next, else the last one finished. Same order the strip is laid out in, so
  # the page opens on the chip at the far left rather than somewhere in the
  # middle of a row the reader has to go looking through.
  #
  # After first paint the choice belongs to the reader (Alpine `focus`, declared
  # outside every broadcast target so a score cannot reset it). This only picks
  # the starting one.
  def default_focus_game_slug(games)
    (games[:active].first || games[:upcoming].first || games[:completed].first)&.slug
  end

  # World Cup Survivor uses rounds + off-chain picks, not slate matchups.
  def load_survivor_board_data
    @survivor_rounds = SurvivorRound.ordered.to_a
    @current_round = @survivor_rounds.find { |r| !r.completed? }
    @entries = @contest.entries.where(status: [:active, :complete])
                       .includes(:user, survivor_picks: [:survivor_round, :team])
                       .to_a
    @my_entry = current_user && @entries.find { |e| e.user_id == current_user.id }
    @pending_recovery_ptx = find_pending_recovery_ptx
  end

  # Stranded onchain entry from a refresh between sign-and-confirm. The
  # board JS reads this on init and POSTs /recover_pending_entry to either
  # auto-promote the entry (TX landed) or release it (TX failed). Returns
  # nil for guests, web2 users, off-chain contests, and the common case
  # where no PT is stranded.
  def find_pending_recovery_ptx
    return nil unless current_user&.web3_solana_address.present? && @contest.onchain?
    stranded = PendingTransaction.where(status: %w[pending submitted],
                                        initiator_address: current_user.web3_solana_address,
                                        target_type: "Entry")
                                 .where(target_id: @contest.entries.where(user_id: current_user.id).select(:id))

    # Operator call (2026-06-11): recovery is ONLY for a PT that actually
    # BROADCAST (carries a tx_signature) — real money may have moved, so the
    # "Checking Your Last Entry" flow must resolve it. A signatureless PT
    # means nothing ever left the building (prepare_entry ran, confirm never
    # broadcast): no modal, no recovery — "if it fails, it fails". Quietly
    # retire the stale ones; the >10min guard leaves a tab that's mid-confirm
    # alone (confirm stamps the signature within seconds of broadcasting,
    # and it looks the PT up by the same pending/submitted scope).
    stranded.where(tx_signature: nil)
            .where(created_at: ..10.minutes.ago)
            .update_all(status: "expired", updated_at: Time.current)

    stranded.where.not(tx_signature: nil).order(created_at: :desc).first
  end

  # Pre-rendered seeds payload used by the contest show page's slate
  # progress card. Cache-first (the navbar preload no longer blocks on the
  # seeds RPC — see ApplicationController): returns the warm cached payload
  # when available, otherwise a zero payload so the card still renders and
  # the seeds_bar self-heals from `seedsNavbar` localStorage + the
  # 'navbar-seeds-update' event that refreshBalance() fires on load. Returns
  # nil for guests / non-wallet users so the view's `<% if @seeds_data %>`
  # gate keeps the card hidden.
  def load_seeds_data
    return unless logged_in? && current_user.solana_connected?
    display_seeds_data || seeds_payload(0)
  end

  def contest_params
    params.require(:contest).permit(:name, :slug, :slate_id, :contest_type, :season_id, :starts_at, :contest_image, :locks_at_date_selected, :locks_at_time_selected, :locks_at_timezone_selected)
  end

  # Slates an operator may build a contest on. Weekly NFL slates carry a `week`
  # but no starts_at (the projections feed has no kickoff times), so they'd been
  # invisible to this form entirely — include them and order them by week after
  # the dated slates. #create refuses a contest whose lock time can't be
  # resolved, so a slate with no game times still can't produce a lock_timestamp
  # of 0 on-chain.
  def contest_slate_options
    Slate.where.not(name: "Default")
         .where("starts_at IS NOT NULL OR week IS NOT NULL")
         .order(Arel.sql("starts_at ASC NULLS LAST"), :week)
  end

  def default_start_for_slate(slate)
    slate&.first_game_starts_at || slate&.starts_at
  end

  # Best-effort sport derivation from a slate's name. Slate/Team don't carry
  # a sport column in this app yet; matching the name string is sufficient
  # since slate names are operator-controlled and consistent.
  #   "World Cup 2026 Group 1" → "fifa"
  #   "NFL 2026 Week 1"        → "nfl"
  # Delegates to Slate#sport, which is the single home for this rule — the
  # selector row needs the same classification to pick its 🏈 / ⚽ marker, and
  # two copies of the regex would drift.
  def sport_for_slate(slate)
    slate&.sport || "fifa"
  end

  # :contest_image is intentionally NOT permitted here — the banner saves through
  # its own #update_banner action. Permitting it would let any future field on
  # the edit form submit an empty value and purge the existing attachment.
  def contest_update_params
    params.require(:contest).permit(:name, :tagline, :rank, :starts_at, :locks_at_date_selected, :locks_at_time_selected, :locks_at_timezone_selected, :chat_enabled)
  end
end
