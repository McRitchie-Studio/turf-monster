class Contest < ApplicationRecord
  include Sluggable

  has_many :entries, dependent: :destroy
  has_many :messages, dependent: :destroy
  belongs_to :slate, optional: true

  belongs_to :user, optional: true
  has_one_attached :contest_image

  # Name is repeatable + branded — NO uniqueness. Slug is the unique key.
  # 96-byte cap matches the future on-chain fixed `name` field (Part B / v0.21);
  # validate UTF-8 bytesize, not char length, so multibyte names can't overflow
  # the on-chain buffer.
  validates :name, presence: true
  validate :name_within_byte_limit

  # Slug is the GLOBALLY-unique, manually-set identifier. It seeds the on-chain
  # Contest PDA (contest_id = sha256(slug)) and every URL. Decoupled from name
  # (2026-06-02, name/slug epic Part A) so duplicate names no longer collide on
  # slug OR on the PDA. 64-byte cap matches the future on-chain fixed `slug`.
  NAME_MAX_BYTES = 96
  SLUG_MAX_BYTES = 64
  TURF_TOTALS_DEFAULT_PICKS_REQUIRED = 6
  SLUG_FORMAT = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  validates :slug, presence: true, uniqueness: true, format: { with: SLUG_FORMAT, message: "must be lowercase letters, numbers, and hyphens" }
  validate :slug_within_byte_limit

  # Backfill a slug from the name on create ONLY when none was set explicitly,
  # so `Contest.create!(name:)` (server-funded fallback, seeds, console, tests)
  # still works without re-coupling slug to name. Runs at before_validation so
  # the presence/format/uniqueness checks see the backfilled value. An explicit
  # slug is left untouched (the UI create path always supplies one). See #set_slug
  # for why Sluggable's overwrite-on-save is neutralized.
  before_validation :backfill_slug, on: :create

  # Turf Totals contests run off a Slate; World Cup Survivor contests don't.
  validates :slate, presence: true, if: :turf_totals?

  # v0.17: locking is DERIVED from the on-chain lock_timestamp (mirrored to
  # starts_at), not a status. A contest stays `open` right up to `settled`;
  # `locked?` below computes the gate. The on-chain Contest PDA keeps a vestigial
  # `Locked` enum slot, but nothing sets it. (Pre-v0.17 had a `locked` status.)
  enum :status, { pending: "pending", open: "open", settled: "settled" }
  enum :game_type, { turf_totals: "turf_totals", world_cup_survivor: "world_cup_survivor" }

  # "All contests on chain" enforcement (2026-05-17 GTM principle):
  # every Contest is backed by an on-chain Contest PDA on turf-vault.
  #
  # PRIMARY PATH — Phantom-funded (default for the /contests/new UI):
  #   ContestsController#create builds a partially-signed `create_contest`
  #   TX (admin pays SOL rent, creator slot left for Phantom). User signs
  #   in their wallet → broadcast + confirm → ContestsController#finalize
  #   creates the DB row with `skip_onchain_callback = true` and the
  #   onchain_contest_id / onchain_tx_signature already populated.
  #   See app/views/contests/new.html.erb + Solana::Vault#build_create_contest.
  #
  # FALLBACK PATH — server-funded (Rails console / operator scripts):
  #   `Contest.create!(...)` without `skip_onchain_callback = true` fires
  #   the after_create callback below, which calls `create_onchain!` →
  #   Solana::Vault#create_contest_server_funded. Admin signs as both
  #   payer + creator and funds the prize pool from custodial USDC. If the
  #   on-chain leg fails, the DB row is destroyed and the exception
  #   re-raised — so `create!` is atomic across DB + chain.
  #
  # Opt-out via `skip_onchain_callback = true`:
  #   - The Phantom-funded UI flow sets this on save (Contest is already on-chain).
  #   - Test fixtures + Rails tests (Rails.env.test? auto-skips).
  attr_accessor :skip_onchain_callback
  after_create :create_onchain_with_rollback!, unless: :skip_onchain_callback_active?


  # OPSEC-023: bind each contest to the active season at creation. turf-vault
  # v0.13.0 stores season_id on the Contest PDA and rejects any entry whose
  # Season account doesn't match it, so entries must always pass this season.
  before_create { self.season_id ||= SeasonConfig.current_season_id }

  scope :ranked, -> { where.not(rank: nil).order(rank: :asc) }

  def self.target
    ranked.find_by(status: :open)
  end

  # The contest the app spotlights — the admin-set main contest, else its
  # open-only fallback, else the newest open/settled (a freshly-graded contest
  # still serves as a leaderboard landing until a newer one opens). Single source
  # of truth for the root redirect (ContestsController#world_cup) and the
  # magic-link sign-in landing (MagicLinksController).
  def self.featured
    SeasonConfig.main_contest_explicit ||
      SeasonConfig.main_contest ||
      where(status: [:open, :settled]).order(created_at: :desc).first
  end

  # ─── Multi-week span ────────────────────────────────────────────────
  #
  # A multi-week contest is played on ONE Slate that holds several games per team
  # (see Nfl::BuildSpanSlate) — NOT on a set of weekly slates joined to the
  # contest. That earlier shape is what forced the span multiplier to be
  # recomputed live across slates, and a live multiplier drifted between pick
  # time and settlement (measured 1.0x -> 3.0x). Now the slate stores a frozen
  # per-team turf_score at rank time and everything reads it.
  #
  # `slate_id` therefore stays a plain scalar FK, and picks_required, locking,
  # assert_enterable!, and Game#score_affected_contests! are all unchanged.

  def multi_week?
    slate&.multi_game_per_team? || false
  end

  def weeks_count
    slate&.games_per_team.to_i
  end

  # "Week 3" / "Weeks 1-3" for headers and cards. Nil when the slate carries no
  # week (World Cup), so callers fall back to the slate name.
  def week_span_label
    slate&.week_range_label
  end

  # The full pool of matchups. On a span slate this is every team's every game.
  def matchups
    slate.slate_matchups
  end

  # The PICKABLE rows — one per team. On a single-week slate that is just the
  # matchups; on a span slate it is each team's first game, which anchors the
  # Selection. A pick is a TEAM either way.
  def pickable_matchups
    return matchups unless multi_week?

    slate.matchups_by_team.values.map(&:first)
  end

  # Every game a picked team plays in this contest — the scoring set behind one
  # Selection. Single-week: that one matchup.
  def matchups_for_team(team_slug)
    slate ? slate.matchups_by_team[team_slug].to_a : []
  end

  # Whole-slate matchups grouped by team, for callers that need MANY teams at
  # once (the leaderboard renders six picks per entry). One query, not one per
  # pick per row.
  def matchups_by_team
    slate ? slate.matchups_by_team : {}
  end

  # The team's FROZEN multiplier — stored on its matchup rows at rank time, the
  # same column Selection#compute_points! settles from and the slate page
  # renders. Reading it (rather than recomputing) is what makes the price a
  # player is shown the price they are paid.
  def span_turf_score_for(team_slug)
    matchups_for_team(team_slug).first&.turf_score
  end

  def picks_required
    return 0 if world_cup_survivor?

    self.class.picks_required_for_slate(slate)
  end

  def max_entries_per_user
    world_cup_survivor? ? 1 : 3
  end

  def entry_fee_dollars
    entry_fee_cents / 100.0
  end

  def guaranteed_prize_cents
    payouts.values.sum
  end

  def guaranteed_prize_dollars
    guaranteed_prize_cents / 100.0
  end

  def pool_cents
    entries.where(status: [:active, :complete]).count * entry_fee_cents
  end

  def pool_dollars
    pool_cents / 100.0
  end

  # GTM contest tiers (defined 2026-05-17). All at $19 entry fee.
  # Margin per filled contest = gross revenue (entries × fee) − total payouts.
  #   tiny     :  3 entries → $57   gross / $45   payout / $12 margin (78.9%)
  #   small    :  5 entries → $95   gross / $75   payout / $20 margin (78.9%)
  #   medium   :  9 entries → $171  gross / $140  payout / $31 margin (81.9%)
  #   standard : 29 entries → $551  gross / $500  payout / $51 margin (90.7%)
  #   large    : 99 entries → $1881 gross / $1800 payout / $81 margin (95.7%)
  FORMATS = {
    "tiny"     => { entry_fee_cents: 19_00, max_entries: 3,  payouts: { 1 => 45_00 } },
    "small"    => { entry_fee_cents: 19_00, max_entries: 5,  payouts: { 1 => 75_00 } },
    "medium"   => { entry_fee_cents: 19_00, max_entries: 9,  payouts: { 1 => 100_00, 2 => 40_00 } },
    "standard" => { entry_fee_cents: 19_00, max_entries: 29, payouts: { 1 => 300_00, 2 => 50_00, 3 => 50_00, 4 => 50_00, 5 => 50_00 } },
    "large"    => { entry_fee_cents: 19_00, max_entries: 99, payouts: { 1 => 1000_00, 2 => 100_00, 3 => 100_00, 4 => 100_00, 5 => 100_00, 6 => 100_00, 7 => 100_00, 8 => 100_00, 9 => 100_00 } },

    # World Cup Survivor — single guaranteed prize, 59 entrants, one entry per user.
    # Paid margin (full): $1,121 gross - $1,000 payout = $121. Free contest is a loss-leader.
    "survivor_wc_paid" => { entry_fee_cents: 19_00, max_entries: 59, payouts: { 1 => 1000_00 } },
    "survivor_wc_free" => { entry_fee_cents: 0,     max_entries: 59, payouts: { 1 => 200_00 } },

    # Test scaffolding — $1 entry, gated behind ENABLE_TEST_SCAFFOLDING (AppFlags.test_scaffolding?).
    # A low-stakes end-to-end rehearsal tier: 9 entries → $9 gross / $9 payout / $0 margin.
    # BREAK-EVEN BY DESIGN (operator call, 2026-08-27): this tier exists to rehearse the full
    # entry → onchain → grade → payout path with real money at pocket-change stakes, not to earn.
    # A short fill loses money: grading pays only the ranks that EXIST (see max_paid_rank
    # below), so 1 entry pays $5 (-$4), 2 pay $7 (-$5), and 3+ pay the full $9 — making
    # THREE entries the worst case at -$6, not one. That is the accepted cost of the
    # rehearsal, and the reason the tier stays flag-gated.
    # Hidden from the create UIs unless the flag is on; DISABLE before the public launch.
    # FORMATS still lists it always so an existing micro contest resolves config + grades
    # correctly — which also FREEZES this payout table once a micro contest exists on-chain:
    # payouts are re-derived from here at grade time, so editing them would settle against a
    # prize_pool PDA funded at the old numbers (settle_contest.rs SettlementOverflow).
    "micro"            => { entry_fee_cents: 1_00, max_entries: 9, payouts: { 1 => 5_00, 2 => 2_00, 3 => 2_00 } }
  }.freeze

  # Format keys hidden from the contest-create UIs unless ENABLE_TEST_SCAFFOLDING is on.
  TEST_FORMAT_KEYS = %w[micro].freeze

  # Formats an operator may pick in the create UIs (new-contest form + generator
  # matrix). FORMATS itself always contains every format so #format_config and
  # grading keep working for a contest created while the flag was on.
  def self.selectable_formats
    AppFlags.test_scaffolding? ? FORMATS : FORMATS.except(*TEST_FORMAT_KEYS)
  end

  def self.picks_required_for_slate(slate)
    matchup_count = slate&.slate_matchups&.count.to_i
    return TURF_TOTALS_DEFAULT_PICKS_REQUIRED if matchup_count.zero?

    [matchup_count, TURF_TOTALS_DEFAULT_PICKS_REQUIRED].min
  end

  def format_config
    FORMATS[contest_type] || FORMATS["standard"]
  end

  def payouts
    format_config[:payouts]
  end

  # On-chain Contest PDA creation, server-funded (admin pays prize pool).
  # Invoked automatically by the after_create callback. Idempotent — re-running
  # on an already-onchain Contest is a no-op. Raises on RPC / TX failure;
  # caller (the after_create) destroys the DB row on failure so create! is atomic.
  #
  # Manual invocation (e.g. re-trying after a transient RPC failure):
  #   Contest.find_by(slug: "...").create_onchain!
  def create_onchain!
    return if onchain?
    return if entry_fee_cents.nil? || max_entries.nil?

    vault = Solana::Vault.new
    result = vault.create_contest_server_funded(
      contest_slug:          slug,
      entry_fee_by_currency: onchain_params[:entry_fee_by_currency],
      max_entries:           max_entries,
      payout_amounts:        onchain_params[:payout_amounts],
      prize_pool:            onchain_params[:prize_pool],
      season_id:             season_id || SeasonConfig.current_season_id,
      lock_timestamp:        onchain_params[:lock_timestamp]
    )
    update!(
      onchain_contest_id:   result[:contest_pda],
      onchain_tx_signature: result[:tx_signature],
      # onchain_params funded entry_fee_by_currency slot 1 (USDT) above, so
      # this contest can take currency_idx 1 entries. See the accepts_usdt
      # migration note — pre-2026-06-10 contests stay false.
      accepts_usdt:         true
    )
    result
  end

  def skip_onchain_callback_active?
    skip_onchain_callback || onchain? || Rails.env.test?
  end

  # after_create callback: ensures on-chain Contest PDA exists for every new
  # Contest. If on-chain creation fails, destroys the DB row so callers see
  # a clean "contest not created" outcome instead of a half-created state.
  def create_onchain_with_rollback!
    create_onchain!
  rescue => e
    Rails.logger.error("[Contest.create_onchain!] FAILED for slug=#{slug}: #{e.class}: #{e.message}")
    destroy
    raise "On-chain contest creation failed (DB row rolled back): #{e.message}"
  end

  def grade!
    with_lock do
      raise "Contest is already settled" if settled?
      # v0.19 (#6): the program rejects settle until the lock (or conclusion)
      # has passed — entries must be provably closed before grading. Gate here,
      # before any off-chain grading, so we don't grade in the DB then fail the
      # on-chain settle with 6028. `locked?` mirrors the on-chain lock_timestamp.
      raise "Cannot grade: the contest lock time hasn't passed — entries are still open." if onchain? && !locked?
      # World Cup Survivor sets entry scores during round grading — skip matchup scoring.
      score_entries! unless world_cup_survivor?

      # `id: :asc` is a deterministic tiebreaker: tied scores order by creation,
      # so the integer-remainder payout split (below) always credits the earliest
      # entry. Without it Postgres returns ties in physical/arbitrary order, making
      # the split non-deterministic (a money bug + flaky tests once other rows exist).
      ranked = entries.where(status: [:active, :complete]).order(score: :desc, id: :asc).includes(:user).to_a
      ranked.each { |e| e.update!(status: "complete") if e.active? }
      ranked = entries.complete.order(score: :desc, id: :asc).includes(:user).to_a

      return update!(status: "settled") if ranked.empty?

      # Build ranks (ties get same rank)
      ranks = []
      ranked.each_with_index do |entry, i|
        rank = if i == 0
          1
        elsif entry.score < ranked[i - 1].score
          i + 1
        else
          ranks.last
        end
        ranks << rank
      end

      # Pay out based on format payouts
      max_paid_rank = payouts.keys.max || 0
      ranked.each_with_index do |entry, i|
        rank = ranks[i]
        share = 0

        if rank <= max_paid_rank
          tied_indices = ranks.each_index.select { |j| ranks[j] == rank }
          tied_count = tied_indices.size
          spanned_ranks = (rank..(rank + tied_count - 1)).to_a
          total_prize = spanned_ranks.sum { |r| payouts[r] || 0 }
          base_share = total_prize / tied_count
          remainder = total_prize % tied_count
          position_in_tie = tied_indices.index(i)
          share = position_in_tie < remainder ? base_share + 1 : base_share
          if share > 0
            TransactionLog.record!(user: entry.user, type: "payout", amount_cents: share, direction: "credit", source: self, description: "Payout rank ##{rank} for #{name}")
          end
        end

        entry.update!(rank: rank, payout_cents: share)
      end

      update!(status: "settled")

      # Attempt onchain settlement (non-blocking)
      settle_onchain! if onchain?
    end
  end

  def jump!
    raise "Contest is already settled" if settled?

    transaction do
      # Simulate all pending games
      matchups.pending.includes(:game).each do |matchup|
        game = matchup.game
        next unless game

        unless game.status == "completed"
          home_score = rand(0..5)
          away_score = rand(0..5)
          game.update!(home_score: home_score, away_score: away_score, status: "completed")
        end

        if matchup.team_slug == game.home_team_slug
          matchup.update!(goals: game.home_score, status: "completed")
        elsif matchup.team_slug == game.away_team_slug
          matchup.update!(goals: game.away_score, status: "completed")
        end
      end

      grade!
    end
  end

  def fill!(users:)
    raise "Contest is not open" unless open?

    matchup_ids = matchups.pluck(:id)
    raise "Need at least #{picks_required} matchups" if matchup_ids.size < picks_required

    active_count = entries.where(status: [:active, :complete]).count
    slots = (max_entries || format_config[:max_entries]) - active_count
    return if slots <= 0

    existing_combos = entries.where(status: [:active, :complete]).includes(:selections).map do |entry|
      entry.selections.map(&:slate_matchup_id).sort
    end.to_set

    user_cycle = users.cycle
    attempts = 0

    slots.times do
      combo = nil
      loop do
        attempts += 1
        break if attempts > slots * 100
        # Pick the contest's required number of non-locked matchups.
        available = matchups.reject(&:locked?).map(&:id)
        next if available.size < picks_required
        combo = available.sample(picks_required).sort
        break unless existing_combos.include?(combo)
        combo = nil
      end
      break unless combo

      existing_combos << combo
      user = user_cycle.next
      entry = entries.create!(user: user, contest: self)
      combo.each do |matchup_id|
        entry.selections.create!(slate_matchup_id: matchup_id)
      end
      # Admin-seeded fill — comped, so it bypasses the entry payment gate.
      entry.confirm!(comped: true)
    end
  end

  def reset!
    transaction do
      entries.destroy_all
      matchups.update_all(goals: nil, status: "pending")
      matchups.includes(:game).find_each do |matchup|
        matchup.game&.update!(home_score: nil, away_score: nil, status: "scheduled")
      end
      update!(status: :open)
    end
  end

  def simulate_games!(count)
    simulated = 0
    count.times do
      break if matchups.pending.includes(:game).none? { |m| m.game.present? }
      simulate_next_game!
      simulated += 1
    end
    simulated
  end

  def simulate_next_game!
    raise "Contest is already settled" if settled?

    # Find next unplayed game (by kickoff_at)
    matchup = matchups.pending.includes(:game).select { |m| m.game.present? }
      .sort_by { |m| m.game.kickoff_at || Time.current }
      .first

    raise "No pending games to simulate" unless matchup

    game = matchup.game
    home_score = rand(0..5)
    away_score = rand(0..5)
    game.update!(home_score: home_score, away_score: away_score, status: "completed")

    # Update all matchups for this game
    game_matchups = matchups.where(game_slug: game.slug)
    game_matchups.each do |m|
      # Figure out which team's goals to record
      if m.team_slug == game.home_team_slug
        m.update!(goals: home_score, status: "completed")
      elsif m.team_slug == game.away_team_slug
        m.update!(goals: away_score, status: "completed")
      end
    end

    # Recompute points for all entries with selections on these matchups
    score_entries!

    # simulate bypasses the Goal callbacks (which normally fire
    # LiveBroadcast.goal_scored), so trigger the live broadcast here —
    # FINAL toast + leaderboard/games refresh. Without this the /live page
    # keeps showing stale scores until a manual page refresh.
    Contest::LiveBroadcast.score_changed(game, event: :game_completed)
    game
  end

  def score_entries!
    entries.where(status: [:active, :complete]).includes(selections: :slate_matchup).find_each(&:score!)
    touch # Bust show page cache after scoring
  end

  # --- Onchain ---

  def onchain?
    onchain_contest_id.present?
  end

  # On-chain cancellation (cancel_contest, 2-of-3). A cancelled contest is
  # terminal — entries are refunded to the creator and no new entry may be
  # submitted. Aliased as #cancelled? for read sites that don't care it's an
  # on-chain flag. Distinct from #settled? (the other terminal state).
  def cancelled?
    onchain_cancelled?
  end

  def onchain_params
    fee_cents  = entry_fee_cents.to_i
    guaranteed = guaranteed_prize_cents
    payout_amounts = payouts.values.map { |c| Solana::Config.dollars_to_lamports(c / 100.0) }

    # v0.16: per-currency entry-fee schedule. Index = currency_idx into the
    # vault's accepted_currencies registry: slot 0 = USDC, slot 1 = USDT.
    # Both are 6-decimal mints, so the same dollar fee is the same lamport
    # amount in both slots. The array is IMMUTABLE after create_contest —
    # contests created before slot 1 was populated (2026-06-10) have a zero
    # USDT fee on-chain forever and stay USDC-only (accepts_usdt: false).
    fee_lamports = Solana::Config.dollars_to_lamports(fee_cents / 100.0)
    entry_fee_by_currency = Array.new(16, 0)
    entry_fee_by_currency[0] = fee_lamports # USDC
    entry_fee_by_currency[1] = fee_lamports # USDT

    {
      entry_fee_by_currency: entry_fee_by_currency,
      max_entries:           max_entries || format_config[:max_entries],
      payout_amounts:        payout_amounts,
      prize_pool:            Solana::Config.dollars_to_lamports(guaranteed / 100.0),
      season_id:             season_id || SeasonConfig.current_season_id,
      # Derived lock (v0.17): mirror the displayed start → on-chain lock_timestamp.
      # nil starts_in_at → 0 = no scheduled lock (manual-only).
      lock_timestamp:        starts_in_at&.to_i || 0
    }
  end

  def settle_onchain!
    return unless onchain? && !onchain_settled?

    winners = entries.complete.where("payout_cents > 0").includes(:user).map do |entry|
      {
        wallet: entry.user.solana_address,
        entry_num: entry.entry_number || 0,
        rank: entry.rank || 0,
        payout: Solana::Config.dollars_to_lamports(entry.payout_cents / 100.0)
      }
    end.select { |w| w[:wallet].present? }

    return update!(onchain_settled: true) if winners.empty?

    # Build partially-signed TX for multisig cosigning
    vault = Solana::Vault.new
    # Use first non-admin signer as default cosigner placeholder
    cosigner = Solana::Config::MULTISIG_COSIGNER rescue Solana::Keypair.admin.to_base58
    result = vault.build_settle_contest(slug, winners, cosigner_pubkey: cosigner)

    PendingTransaction.create!(
      tx_type: "settle_contest",
      serialized_tx: result[:serialized_tx],
      target: self,
      initiator_address: Solana::Keypair.admin.to_base58,
      metadata: { settlements: winners }.to_json
    )
  rescue => e
    ErrorLog.capture!(e)
    # Don't block DB settlement — onchain can be retried
  end

  # Notify every winner (payout_cents > 0) of their winnings by email, AFTER
  # the on-chain settlement has landed. Delegates to Contests::WinnerNotifier
  # (enqueues a background job per emailable winner; skips wallet-only winners;
  # idempotent on repeat calls via each entry's winner_notified_at flag).
  #
  # Trigger: Admin::PendingTransactionsController#confirm calls this once a
  # settle_contest tx confirms and onchain_settled flips true. Also callable
  # standalone from the console to (re-)notify an already-settled contest.
  def notify_winners!
    Contests::WinnerNotifier.call(self)
  end

  def locks_at
    starts_in_at
  end

  def starts_in_at
    starts_at || slate&.first_game_starts_at || slate&.starts_at
  end

  # Derived lock state (v0.17). The authoritative lock lives on-chain
  # (enter_contest rejects once Clock time >= lock_timestamp); this mirrors it
  # from `starts_at` for UI + advisory pre-checks. nil starts_at = no scheduled
  # lock (manual-only) → never derived-locked. A settled contest reads locked.
  def locked?
    return true if settled?
    starts_in_at.present? && Time.current >= starts_in_at
  end

  # Derived conclusion state (v0.18). Mirrors the on-chain conclusion_timestamp
  # (enter is gated by lock; the conclusion gates set_contest_lock_time and
  # marks "results final"). nil concludes_at = no conclusion scheduled.
  def concluded?
    return true if settled?
    concludes_at.present? && Time.current >= concludes_at
  end

  # The contest is live (in-progress) once it has locked but not yet settled —
  # entries are closed and games are being played. The /contests/:id/live page
  # and its real-time broadcasts key off this.
  def live?
    locked? && !settled?
  end

  # This contest's games bucketed for the live page. There's no on-chain
  # in-progress status, so "active" is inferred: a game is live if it has goals
  # OR its kickoff has passed, as long as it isn't completed. (Test games carry
  # future kickoffs, so scoring a goal is what flips a scheduled game live.)
  # Games come off the slate matchups (each carries a :game; some may have none).
  # Shared by ContestsController#live and Contest::LiveBroadcast so the buckets
  # never drift.
  def games_by_phase(now = Time.current)
    games = matchups.includes(game: [:home_team, :away_team, { goals: :player }]).map(&:game).compact.uniq
    # Classify each game once so the active/upcoming split has a single source of
    # truth — no mirrored negation to keep in sync.
    buckets = games.group_by do |g|
      if g.status == "completed"
        :completed
      elsif g.goals.any? || (g.kickoff_at.present? && g.kickoff_at <= now)
        :active
      else
        :upcoming
      end
    end
    {
      active:    (buckets[:active]    || []).sort_by { |g| g.kickoff_at || now },
      upcoming:  (buckets[:upcoming]  || []).sort_by { |g| g.kickoff_at || (now + 100.years) },
      completed: (buckets[:completed] || []).sort_by { |g| g.kickoff_at || now }.reverse
    }
  end

  def lock_time_display
    start_time_display
  end

  def start_time_display
    return "TBD" unless starts_in_at
    starts_in_at.strftime("Starts %B %-d, %Y @ %-I:%M %p")
  end

  def active_entry_count
    entries.where(status: [:active, :complete]).count
  end

  # Who may post in this contest's chat: admins, or anyone with a confirmed
  # entry. Cart/abandoned entries don't count. Everyone can *read* the chat.
  def chat_participant?(user)
    return false unless user
    return true if user.admin?
    entries.where(user_id: user.id, status: [:active, :complete]).exists?
  end

  # The contest's sport as an emoji — drives the first chat quick-reaction
  # (see messages/_message). Every contest today is World Cup soccer; this is
  # the single place to branch when other sports ship a contest type (the
  # emoji must also be in Reaction::SPORTS so the toggle endpoint accepts it).
  def sport_emoji
    "⚽"
  end

  # Still referenced by Entry#name_slug (entry slugs embed the contest slug) and
  # by the contest generator/bundle paths as a suggested slug. NOT the source of
  # the persisted `slug` anymore.
  def name_slug
    name.parameterize
  end

  private


  # NEUTRALIZE Sluggable's auto-derive. Sluggable runs `before_save :set_slug`,
  # which by default does `self.slug = name_slug` on EVERY save — that re-couples
  # slug to name, so a duplicate name re-collides on slug AND on the on-chain PDA
  # (contest_id = sha256(slug)). Override it to a NO-OP for Contest: the slug is
  # set explicitly (UI create path) or backfilled once on create (see
  # #backfill_slug), and is NEVER overwritten from the name afterwards — rename
  # the contest and the slug + its PDA stay put. The slug column + Sluggable's
  # `to_param` (slug-based URLs) are preserved; only the auto-overwrite is killed.
  def set_slug
    # intentionally no-op — Contest slug is decoupled from name (epic Part A)
  end

  # Concurrent-backfill safety. #backfill_slug probes for a free generated slug
  # before insert, but two simultaneous `Contest.create!(name:)` calls (seeds,
  # the server-funded fallback, parallel jobs) can both probe the SAME base, both
  # see it free, and then race the insert — the DB unique index on `slug` lets
  # exactly one win and raises ActiveRecord::RecordNotUnique on the loser. Only
  # backfilled slugs are auto-regenerated + retried here; an EXPLICIT slug that
  # collides must still surface the validation/uniqueness error to the caller
  # (the UI create path supplies its own slug and expects a clear "taken" error).
  MAX_BACKFILL_SLUG_RETRIES = 5
  def create_or_update(...)
    attempts = 0
    begin
      super
    rescue ActiveRecord::RecordNotUnique => e
      raise unless @slug_backfilled && (attempts += 1) <= MAX_BACKFILL_SLUG_RETRIES
      raise unless e.message.to_s.include?("index_contests_on_slug") || e.message.to_s.include?("slug")

      self.slug = generate_unique_backfill_slug
      retry
    end
  end

  # One-time slug backfill for new records created WITHOUT an explicit slug
  # (`Contest.create!(name:)` from the server-funded fallback, seeds, console,
  # tests). Derives from the name and de-dupes with a short random suffix so two
  # new contests with the SAME name don't collide on the generated slug. A slug
  # supplied by the caller is left untouched. Skipped on update — existing
  # contests keep their stored slug.
  def backfill_slug
    return if slug.present?
    return if name.blank?

    @slug_backfilled = true
    self.slug = generate_unique_backfill_slug
  end

  # Derive a url-safe, globally-unique slug from the name. The probe loop
  # de-dupes against committed rows; the DB unique index is the real arbiter
  # (see #create_or_update for the concurrent-insert retry). A blank name_slug
  # (e.g. a name of only non-url-safe chars) falls back to a pure hex slug so
  # the SLUG_FORMAT/presence validations always see a valid value.
  def generate_unique_backfill_slug
    base = name_slug.presence || "contest-#{SecureRandom.hex(3)}"
    candidate = base
    candidate = "#{base}-#{SecureRandom.hex(2)}" while Contest.where(slug: candidate).exists?
    candidate
  end

  def name_within_byte_limit
    return if name.blank?
    if name.to_s.bytesize > NAME_MAX_BYTES
      errors.add(:name, "is too long (maximum is #{NAME_MAX_BYTES} bytes)")
    end
  end

  def slug_within_byte_limit
    return if slug.blank?
    if slug.to_s.bytesize > SLUG_MAX_BYTES
      errors.add(:slug, "is too long (maximum is #{SLUG_MAX_BYTES} bytes)")
    end
  end
end
