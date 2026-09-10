# The worked examples on /turf-monster-v1, as DATA rather than markup.
#
# WHY THIS IS NOT JUST TYPED INTO THE VIEW. The page's whole claim is that its
# numbers are the real ones, and a number typed into ERB is a number nobody can
# check. Here, only the INPUTS are written down — a team, its rank on the live
# Weeks 1-3 board, and (for the scoring example) the points it scored each week.
# Everything the page PRINTS is derived:
#
#   turf_score  <- SlateMatchup.turf_score_for(rank, 32, sport: "nfl"), the same
#                  curve that prices the real board
#   points      <- weekly_points.sum * turf_score, the same shape as
#                  Selection#compute_points! on a span slate
#
# So the multipliers cannot drift from the formula, the scoring table cannot add
# up wrong, and re-tuning the curve re-prices this page with the board.
#
# The RANKS are a snapshot of the live "NFL 2026 Weeks 1-3" slate (read
# 2026-09-06) — the one input that is asserted rather than derived. The weekly
# point totals are invented, and the page says so where it prints them.
module TurfMonsterRules
  # Every NFL slate ranks all 32 teams, which fixes the curve's denominator.
  TEAM_COUNT = 32

  # One team as the page presents it: who they are, where they sit on the board,
  # who they play, and — in the scoring example — what they scored.
  Example = Data.define(:team_slug, :rank, :opponent_slugs, :weekly_points) do
    # The multiplier, from the shipped curve. NEVER a typed number.
    def turf_score
      SlateMatchup.turf_score_for(rank, TurfMonsterRules::TEAM_COUNT, sport: "nfl")
    end

    # Points on the scoreboard, summed across the span — the unit an NFL
    # selection scores on (SlateMatchup#goals holds points for football).
    def points_scored
      weekly_points.sum
    end

    # What the entry is credited: span points times the frozen multiplier.
    def entry_points
      (points_scored * turf_score).round(1)
    end
  end

  # The card in "The Basics". Atlanta because a mid-pack team makes the point
  # better than either extreme: a real multiplier, three real opponents.
  FEATURE = Example.new(
    team_slug: "atlanta-falcons", rank: 26,
    opponent_slugs: %w[pittsburgh-steelers carolina-panthers green-bay-packers],
    weekly_points: [17, 27, 20]
  )

  # The six-team example entry, favorites through longshots, in board order.
  LINEUP = [
    Example.new(team_slug: "baltimore-ravens", rank: 2,
                opponent_slugs: %w[indianapolis-colts new-orleans-saints dallas-cowboys],
                weekly_points: [24, 31, 27]),
    Example.new(team_slug: "detroit-lions", rank: 3,
                opponent_slugs: %w[new-orleans-saints buffalo-bills new-york-jets],
                weekly_points: [20, 17, 34]),
    Example.new(team_slug: "buffalo-bills", rank: 8,
                opponent_slugs: %w[houston-texans detroit-lions los-angeles-chargers],
                weekly_points: [28, 21, 24]),
    Example.new(team_slug: "houston-texans", rank: 15,
                opponent_slugs: %w[buffalo-bills cincinnati-bengals indianapolis-colts],
                weekly_points: [13, 20, 23]),
    FEATURE,
    Example.new(team_slug: "arizona-cardinals", rank: 32,
                opponent_slugs: %w[los-angeles-chargers seattle-seahawks san-francisco-49ers],
                weekly_points: [10, 23, 17])
  ].freeze

  # The three points on the curve section 03 names: both ends and the middle.
  CURVE = [
    { team_slug: "san-francisco-49ers", rank: 1,  note: "Safest points, smallest multiplier" },
    { team_slug: "jacksonville-jaguars", rank: 16, note: "Middle of the board, balanced" },
    { team_slug: "arizona-cardinals",    rank: 32, note: "Every point counts double" }
  ].freeze

  # THE CONTEST THE PAGE PRICES ITSELF AGAINST. Read from Contest::FORMATS, not
  # typed, for the same reason the multipliers are derived: review found the
  # money hard-typed in two sections while the multipliers were derived, and
  # FORMATS carries five other live formats with different sizes and payouts.
  # Change a payout in the app and this page changes with it.
  EXAMPLE_FORMAT = "medium".freeze

  def self.example_format
    Contest::FORMATS.fetch(EXAMPLE_FORMAT)
  end

  # [[place, dollars], ...] in finishing order.
  def self.example_payouts
    example_format[:payouts].sort_by(&:first).map { |place, cents| [ place, cents / 100.0 ] }
  end

  def self.example_prize_pool
    example_format[:payouts].values.sum / 100.0
  end

  def self.example_max_entries
    example_format[:max_entries]
  end

  # THE COMPARISON SECTION 04'S LEAD SENTENCE MAKES, derived so the prose cannot
  # point at the wrong rows or quote a stale delta. Review caught exactly that:
  # the sentence said "the bottom two rows" while the teams it named were the
  # first and fifth, so a reader following the instruction compared the wrong
  # pair and neither number matched.
  Comparison = Data.define(:favorite, :longshot) do
    # How many fewer points the longshot put on the scoreboard.
    def fewer_points
      favorite.points_scored - longshot.points_scored
    end

    # How far ahead it still finished, after the multiplier.
    def points_ahead
      (longshot.entry_points - favorite.entry_points).round(1)
    end
  end

  # The lowest multiplier in the lineup, against the biggest scorer that beat it
  # on FEWER raw points — the pair that makes the page's whole point.
  def self.comparison
    favorite = LINEUP.min_by(&:turf_score)
    longshot = LINEUP.select { |e| e.points_scored < favorite.points_scored }
                     .max_by(&:entry_points)
    Comparison.new(favorite: favorite, longshot: longshot)
  end

  # The scoring example's footer total.
  def self.lineup_total
    LINEUP.sum(&:entry_points).round(1)
  end

  # Every team slug the page names — its own picks AND their opponents, because
  # the opponent chips wear the opponent's own brand color. One query, no N+1.
  def self.team_slugs
    (LINEUP + [FEATURE]).flat_map { |e| [e.team_slug, *e.opponent_slugs] }
      .concat(CURVE.map { |c| c[:team_slug] })
      .uniq
  end

  # The multiplier for a CURVE row, derived exactly as an Example's is.
  def self.turf_score_for_rank(rank)
    SlateMatchup.turf_score_for(rank, TEAM_COUNT, sport: "nfl")
  end
end
