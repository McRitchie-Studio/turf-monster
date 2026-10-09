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
    value = computed_points
    update!(points: value) unless value.nil?
  end

  # The points #compute_points! would write, without writing them: nil when
  # there is nothing to score yet (no week with goals, or no multiplier). The
  # one formula: the hero laptop's scripted board (LaptopShowcaseEntrants::Script)
  # writes out its single-week branch for its in-memory picks.
  def computed_points
    contest = entry.contest

    if contest&.multi_week?
      scored = scoring_matchups.select { |matchup| matchup.goals.present? }
      return nil if scored.empty?

      # The FROZEN multiplier, stored on the matchup rows at rank time — NOT a
      # value recomputed now. A recomputed one drifted between pick time and
      # settlement (measured 1.0x -> 3.0x) because a projections refresh re-ranks
      # the span after picks are locked. Settlement is on-chain, so a player must
      # be paid at the price they were shown.
      multiplier = slate_matchup.turf_score
      return nil if multiplier.blank?

      scored.sum(&:goals) * multiplier
    else
      return nil unless slate_matchup.goals.present? && slate_matchup.turf_score.present?

      slate_matchup.goals * slate_matchup.turf_score
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

  # ONE ENTRY, ONE ROW PER TEAM.
  #
  # `validates :slate_matchup_id, uniqueness` above is per ROW, and a span slate
  # has several rows per team. On a span each Selection scores the team's goals
  # across the WHOLE span (see #compute_points!), so two rows of one team on one
  # entry would count that team twice.
  #
  # What stopped that before this validation was an accident: the slug is
  # "<entry slug>-<team slug>", `index_selections_on_slug` is unique, and so the
  # second row died as a raw PG::UniqueViolation that the pick endpoints echoed
  # to the player. That index is still the race-safe backstop; this gives the
  # rule a name, a clean message, and a test that does not depend on how a slug
  # happens to be spelled.
  #
  # Only when the pick itself changes: scoring writes `points` through update!,
  # and re-judging the team on every one of those would add a query per
  # selection to every grade.
  #
  # (Down here, and every edit above kept line-for-line, on purpose: docs/workflows
  # cites this file by line number and test/docs/workflow_citation_docs_test.rb
  # holds those citations, so code inserted mid-file re-pins every number below it.)
  validate :team_unique_within_entry, if: :will_save_change_to_slate_matchup_id?

  def team_unique_within_entry
    return unless entry && slate_matchup

    taken = Selection.joins(:slate_matchup)
                     .where(entry_id: entry.id, slate_matchups: { team_slug: slate_matchup.team_slug })
                     .where.not(id: id)
                     .exists?
    errors.add(:base, "#{slate_matchup.team&.name || slate_matchup.team_slug} is already picked in this entry") if taken
  end

  # At the foot of the class so docs/workflows' line citations above hold.
  # OPSEC-048: no new pick on a frozen account's entry (edit_entry, the cart).
  include FrozenAccount::Validation
  validates_account_not_frozen -> { entry&.user }, on: :create
end
