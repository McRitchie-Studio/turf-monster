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
  def self.turf_score_for(rank, n, sport: "fifa")
    return 1.0 if n <= 1

    nfl = sport.to_s == "nfl"
    curve = nfl ? (rank - 1).to_f / (n - 1) : Math.log(rank) / Math.log(n)
    (1.0 + (nfl ? 1.0 : 2.0) * curve).round(1)
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

  def locked?
    game&.kickoff_at.present? && game.kickoff_at <= Time.current
  end

  def compute_turf_score!(n = nil)
    return unless rank.present?
    n ||= slate.slate_matchups.count
    update!(turf_score: self.class.turf_score_for(rank, n, sport: slate.sport))
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
