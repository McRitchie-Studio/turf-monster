class Selection < ApplicationRecord
  include Sluggable

  belongs_to :entry
  belongs_to :slate_matchup

  validates :slate_matchup_id, uniqueness: { scope: :entry_id }

  # Points for one pick.
  #
  # Single week: goals × that matchup's turf_score, unchanged.
  #
  # Multi-week: the picked TEAM rides every week, so this is the team's TOTAL
  # goals across the span × the team's ONE frozen turf_score,
  # which is itself derived from the team's expected points summed over the same
  # weeks. Keeping it to a single multiplier is what makes the format scale from
  # one opponent to three — a player reads exactly the same "points per goal"
  # number they read on a one-week contest.
  #
  # Weeks with no result yet (and bye weeks, which have no matchup at all)
  # contribute no goals, so the leaderboard accrues live as each week completes.
  # With NO week scored yet, points are left untouched — matching single-week.
  def compute_points!
    contest = entry.contest

    if contest&.multi_week?
      scored = scoring_matchups.select { |matchup| matchup.goals.present? }
      return if scored.empty?

      # The FROZEN multiplier, stored on the matchup rows at rank time — NOT a
      # value recomputed now. A recomputed one drifted between pick time and
      # settlement (measured 1.0x -> 3.0x) because a projections refresh re-ranks
      # the span after picks are locked. Settlement is on-chain, so a player must
      # be paid at the price they were shown.
      multiplier = slate_matchup.turf_score
      return if multiplier.blank?

      update!(points: scored.sum(&:goals) * multiplier)
    else
      return unless slate_matchup.goals.present? && slate_matchup.turf_score.present?

      update!(points: slate_matchup.goals * slate_matchup.turf_score)
    end
  end

  def name_slug
    "#{entry.slug}-#{slate_matchup.team_slug}"
  end

  # Per-week breakdown for the leaderboard: [[week, matchup], ...] in week order.
  # On a span slate each of the team's games carries its own week, so the label
  # stays honest rather than guessing from position. Single-week contests return
  # their one pair.
  def weekly_breakdown
    contest = entry.contest
    return [[slate_matchup.week, slate_matchup]] unless contest&.multi_week?

    contest.matchups_for_team(slate_matchup.team_slug).map { |matchup| [matchup.week, matchup] }
  end

  private

  # Single-week: the picked matchup itself. Multi-week: that team's matchup in
  # every week of the contest's span.
  def scoring_matchups
    contest = entry.contest
    return [slate_matchup] unless contest&.multi_week?

    contest.matchups_for_team(slate_matchup.team_slug)
  end
end
