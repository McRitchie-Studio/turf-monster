module Nfl
  # Re-derives an EXISTING span slate's frozen prices under the current pricing
  # rule, in place — the tool for moving a slate that was ranked on summed
  # totals onto the two-line rule (Slate "Two lines").
  #
  # Why this exists rather than a rebuild: Nfl::BuildSpanSlate only rebuilds a
  # slate nobody has picked on, and it destroys and recreates every matchup to
  # do it. This touches only rank + turf_score, keeps every matchup (and so
  # every Selection) in place, and says exactly what it will change first.
  #
  # Money-safety, in order:
  #   * DRY RUN BY DEFAULT. Nothing is written unless `apply: true`.
  #   * A slate whose first game has kicked off is NEVER repriced — a price
  #     change mid-contest re-scores a race already being run. No override.
  #   * A slate with a PAID pick on it (an active or complete entry) is refused
  #     unless the caller passes `reprice_paid_picks: true`. A paid pick was
  #     bought at the price it was shown; changing it is an operator decision,
  #     never a side effect.
  # Cart and abandoned picks never block: nobody has paid for them, and they
  # read the matchup's live price when they are next seen.
  class RepriceSpanSlate
    Change = Data.define(:team_slug, :games, :game_factor, :old_rank, :new_rank,
                         :old_turf_score, :new_turf_score, :paid_picks, :unpaid_picks) do
      def changed?
        old_rank != new_rank || old_turf_score.to_f != new_turf_score.to_f
      end
    end

    Result = Data.define(:slate, :changes, :applied, :refusal) do
      def paid_picks
        changes.sum(&:paid_picks)
      end

      def changed
        changes.select(&:changed?)
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(slate:, apply: false, reprice_paid_picks: false, now: Time.current)
      @slate = slate
      @apply = apply
      @reprice_paid_picks = reprice_paid_picks
      @now = now
    end

    def call
      changes = planned_changes
      refusal = refusal_for(changes)
      applied = false

      if @apply && refusal.nil? && changes.any?(&:changed?)
        write!(changes)
        applied = true
      end

      Result.new(slate: @slate, changes: changes, applied: applied, refusal: refusal)
    end

    private

    def planned_changes
      by_team = @slate.matchups_by_team
      rankings = @slate.team_rankings
      picks = picks_by_team
      paid = picks.merge(Entry.confirmed).count
      all = picks.count

      rankings.sort_by { |_team_slug, ranking| ranking[:rank] }.map do |team_slug, ranking|
        anchor = by_team.fetch(team_slug).first
        Change.new(
          team_slug: team_slug,
          games: ranking[:games],
          game_factor: ranking[:game_factor],
          old_rank: anchor.rank,
          new_rank: ranking[:rank],
          old_turf_score: anchor.turf_score,
          new_turf_score: ranking[:turf_score],
          paid_picks: paid.fetch(team_slug, 0),
          unpaid_picks: all.fetch(team_slug, 0) - paid.fetch(team_slug, 0)
        )
      end
    end

    # Every pick on this slate, across every contest played on it, grouped by
    # team. A paid pick is one on a confirmed (active or complete) entry.
    def picks_by_team
      Selection.joins(:slate_matchup, :entry)
               .where(slate_matchups: { slate_id: @slate.id })
               .group("slate_matchups.team_slug")
    end

    def refusal_for(changes)
      kickoff = @slate.first_game_starts_at
      if kickoff && kickoff <= @now
        return "#{@slate.name} kicked off at #{kickoff.utc.iso8601} — a started slate is never repriced"
      end

      paid = changes.sum(&:paid_picks)
      if paid.positive? && !@reprice_paid_picks && changes.any?(&:changed?)
        return "#{@slate.name} carries #{paid} paid pick#{'s' unless paid == 1} — " \
               "repricing them needs an explicit operator decision (reprice_paid_picks)"
      end

      nil
    end

    # Every row of a team carries the team's price (Selection#compute_points!
    # settles from the picked row), so every row moves together.
    def write!(changes)
      ActiveRecord::Base.transaction do
        changes.select(&:changed?).each do |change|
          @slate.slate_matchups.where(team_slug: change.team_slug)
                .update_all(rank: change.new_rank, turf_score: change.new_turf_score, updated_at: @now)
        end
      end
    end
  end
end
