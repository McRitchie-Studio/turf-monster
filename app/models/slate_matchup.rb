class SlateMatchup < ApplicationRecord
  include Sluggable

  belongs_to :slate
  belongs_to :team, foreign_key: :team_slug, primary_key: :slug
  belongs_to :opponent_team, class_name: "Team", foreign_key: :opponent_team_slug, primary_key: :slug, optional: true
  belongs_to :game, foreign_key: :game_slug, primary_key: :slug, optional: true

  has_many :selections, dependent: :destroy

  # A team appears once per GAME it plays in the slate — a "Weeks 1-3" slate
  # holds three rows per team. Scoped on game_slug rather than the slate alone,
  # which is what used to cap a team at one appearance.
  #
  # This also covers what the DB index can't: game_slug is nullable and PG 14
  # predates NULLS NOT DISTINCT, so the index treats NULL rows as all distinct.
  # Rails generates `game_slug IS NULL` here and catches that case.
  validates :team_slug, uniqueness: { scope: [:slate_id, :game_slug] }

  # Defense in depth, and deliberately only the FLOOR. Every writer that goes
  # through `update!` prices off `.turf_score_for`, which cannot emit below x1.0
  # (see .price_band) — so this can only ever catch a mistake.
  #
  # It is NOT the fix for the admin board: `update_all` skips validations by
  # construction, which is exactly why SlatesController#update_turf_scores checks
  # the band itself before writing. Read this as the net under the OTHER writers,
  # never as the reason that endpoint is safe.
  validates :turf_score, numericality: { greater_than_or_equal_to: 1.0 }, allow_nil: true

  scope :ranked, -> { order(:rank) }
  scope :pending, -> { where(status: "pending") }
  scope :completed, -> { where(status: "completed") }

  # ─── Centralized Formulas ───────────────────────────────────
  # JS mirrors live in show.html.erb and formula_report.html.erb

  # Sport-aware multiplier curve, base PINNED to 1.0 — rank 1 always prices
  # x1.0 (operator rule); only the top end flexes via scale.
  #   fifa: 1.0 + 2.0 * ln(rank)/ln(N)    — goals decay logarithmically, x3 top
  #   nfl:  1.0 + 1.0 * (rank-1)/(N-1)    — points run nearly linear
  #         (measured: the 2023-25 points-distribution fit, r² .958 linear),
  #         x2 top so the Turf and DK curves roughly mirror on the chart
  # Scale defaults mirror Slate#resolved_formula's sport-aware fallback;
  # per-slate overrides resolve at render time and the JS mirrors in
  # slates/show.html.erb use those resolved values.
  #
  # `game_factor` is the TWO-LINE rule for a span with a bye in it (see
  # Slate.game_factor). A full-span team passes 1.0 and prices exactly as
  # before; a team that plays 2 of a span's 3 games passes 1.5 and rides the
  # two-game line, x1.5 to x3.0. Rounded ONCE, after scaling — scaling an
  # already-rounded 1.1 would drift a bye team a tenth off its true line.
  # `scale` is the top of the curve — x2.0 for the NFL, x3.0 for soccer — and it
  # is a PARAMETER here only because the admin slate page lets an operator drag
  # it. Passing nil takes the sport's own default, which is every caller but
  # that page.
  #
  # That the slider had no Ruby parameter is why a second implementation grew in
  # JavaScript, and why the two could disagree: Ruby rounds half away from zero
  # on the decimal, JS `toFixed` rounds the binary double, and they part company
  # on an exact tie. Measured across 74,025 cells (both curves, n 2-48, every
  # slider position, factors 1.0/1.5/3.0): 369 disagreed — none at n=32, so the
  # NFL board was never exposed, but a World Cup slate at n=6 or n=9 was.
  # SlatesHelper#turf_score_scale_table now feeds the page from THIS method, so
  # there is one implementation again and a tie cannot be rounded two ways.
  def self.turf_score_for(rank, n, sport: "fifa", game_factor: 1.0, scale: nil)
    return (1.0 * game_factor).round(1) if n <= 1

    nfl = sport.to_s == "nfl"
    curve = nfl ? (rank - 1).to_f / (n - 1) : Math.log(rank) / Math.log(n)
    ((1.0 + (scale || (nfl ? 1.0 : 2.0)) * curve) * game_factor).round(1)
  end

  # The scale positions the admin board's slider offers — `min="0" max="10"
  # step="0.5"` on slates/show.html.erb. It lives HERE, beside the curve it
  # parameterizes, because THREE things now have to agree on it: the slider, the
  # price table the page looks each row up in (SlatesHelper#turf_score_scale_table),
  # and the band the server accepts back (.price_band below). A second copy is a
  # second rounding rule waiting to happen — see the 369 disagreeing cells above.
  SLIDER_SCALES = (0..20).map { |step| (step * 0.5).round(1) }.freeze

  # A posted multiplier as a number, or nil when the text is not one.
  #
  # This exists because `String#to_f` answers 0.0 for anything it cannot read and
  # never says so: `"2.5x".to_f`, `"".to_f` and `"—".to_f` are all 0.0. On this
  # column those are not the same statement as `"0".to_f` — one is a typo and the
  # other is a price — and `Kernel#Float` is what can tell them apart, because it
  # raises instead of guessing. Rounded to a tenth, the way the board both
  # displays and stores a price.
  #
  # `finite?` is not paranoia: `Float("1e400")` returns Infinity without raising,
  # and `Infinity.round(1)` raises FloatDomainError out of a request.
  def self.parse_turf_score(raw)
    return nil if raw.nil?

    text = raw.to_s.strip
    return nil if text.empty?

    value = Float(text)
    return nil unless value.finite?

    value.round(1)
  rescue ArgumentError, TypeError
    nil
  end

  # The band a HAND-ENTERED multiplier has to land in, as a Range.
  #
  # ── THE PRODUCT DECISION, stated here because the two answers are different
  #    products ──────────────────────────────────────────────────────────────
  #
  # This is a deliberate OVERRIDE band — WIDER than the slate's resolved curve —
  # not the curve's own range. Chosen because the admin board can legitimately
  # display, and "Save Multipliers" legitimately posts, prices above that curve:
  # the scale slider runs 0..10 and repaints every row live, and saving the
  # multipliers is a separate button from saving the formula. A bound set at the
  # resolved curve's top (x2.0 on an NFL slate) would therefore refuse the
  # operator's own screen. A guard that fires on correct work is a guard someone
  # deletes, and then nothing stops the typo either.
  #
  # So the band is the WIDEST PRICE THIS SLATE'S OWN BOARD CAN SHOW, computed
  # from the same two sources the board's prices come from — this curve and
  # SLIDER_SCALES — so the guard cannot drift away from the page. Re-tune either
  # and both move together.
  #
  #   floor   = turf_score_for(rank 1, scale 0)   -> always x1.0
  #   ceiling = turf_score_for(rank n, scale 10)  -> x11.0 * the widest line here
  #
  # The FLOOR is not a judgment call. Every price the curve can emit is
  # (1.0 + scale * curve) * game_factor with scale >= 0, curve >= 0 and
  # game_factor >= 1.0, so x1.0 is its structural minimum and the operator rule
  # ("rank 1 always prices x1.0") pins it there. A price under x1.0 is not a
  # cheap team, it is a bug — and 0.0 is the specific bug this guards.
  #
  # What this DOES leave through, said plainly: on a one-week slate whose curve
  # tops at x2.0, a hand-typed x3.5 is accepted, because the slider can put x3.5
  # on that same screen. The server cannot tell that apart from a deliberate
  # override, and pretending it can is how the slider stops working.
  def self.price_band(teams:, sport: "fifa", game_factors: [1.0])
    factors = Array(game_factors).map(&:to_f).select(&:positive?)
    factors = [1.0] if factors.empty?
    n = [teams.to_i, 1].max

    floor = turf_score_for(1, n, sport: sport, game_factor: factors.min, scale: SLIDER_SCALES.min)
    ceiling = turf_score_for(n, n, sport: sport, game_factor: factors.max, scale: SLIDER_SCALES.max)
    floor..ceiling
  end

  def self.goals_distribution_for(rank, n)
    (0.2 + 4.3 * Math.log(n.to_f / rank) / Math.log(n)).round(2)
  end

  # V3 "anchored" DK Score (restored verbatim from 405f902; dropped with the
  # odds columns in 1fd6c50): integer-anchored line + implied-probability
  # spread, floored at zero. Renders on /slates/formula_report.
  def self.dk_score_for(line, over_odds)
    return nil unless line && over_odds

    prob = if over_odds < 0
      over_odds.abs.to_f / (over_odds.abs + 100)
    else
      100.0 / (over_odds + 100)
    end
    [(line - 0.5) + (prob - 0.5) * 3, 0].max.round(2)
  end

  # ─── Instance Methods ───────────────────────────────────────

  # NOTE — there is deliberately NO per-matchup `compute_turf_score!` here.
  #
  # One existed until `close-pricing-review-notes` and had zero callers, which
  # is the only reason it never mispriced anything: it passed no `game_factor`,
  # so every bye team it touched would have been priced on the full-span line,
  # and it counted `n` as the slate's ROW count — 96 on a three-week span, where
  # the curve's denominator is the 32 TEAMS. Reviving it would have been wrong
  # twice over, and it read like the obvious way to price one row.
  #
  # Every writer of this column ranks the TEAM first, and
  # test/models/turf_score_writers_test.rb holds the list — seven files today,
  # each with the reason it is allowed to write a price. Read that list rather
  # than trusting a count here, which is exactly the kind of number that rots.

  def locked?
    game&.kickoff_at.present? && game.kickoff_at <= Time.current
  end

  # On a SPAN slate a team has several rows, and two of them can share an
  # opponent (a division rival played twice inside the span), which made this
  # slug collide against the unique index and refuse the row outright. Qualify it
  # by week in that case.
  #
  # Deliberately scoped to span slates: Sluggable rewrites the slug on EVERY
  # save, so appending unconditionally would churn every existing weekly
  # matchup's slug for no gain.
  def name_slug
    base = "#{slate.slug}-#{team_slug}-vs-#{opponent_team_slug}"
    return base unless week.present? && slate&.week_range&.size.to_i > 1

    "#{base}-wk#{week}"
  end
end
