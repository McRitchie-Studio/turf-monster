module Nfl
  # Re-reads a span slate's expected scores from its SOURCE weekly slates and
  # reprices it — the market half of a benchmark rebuild, where
  # Nfl::RepriceSpanSlate is the pricing half.
  #
  # WHY IT EXISTS AT ALL: Nfl::BuildSpanSlate is the normal way a span picks up
  # fresh numbers, and it REFUSES a slate that backs any pick — rightly, since it
  # rebuilds by destroying every matchup, which would cascade to live Selections.
  # So once a contest is open on a span, that door is shut, and a market refresh
  # could not reach it. This one updates `expected_score` on the rows already
  # there: no matchup is created or destroyed, no Selection is touched.
  #
  # ORDER MATTERS, AND IT IS ONE TRANSACTION. Fresh expected scores with stale
  # prices is a slate that contradicts itself — the board would show a team's
  # new number beside the multiplier the old number earned. So the refresh and
  # the reprice commit together or not at all: if the reprice refuses (a paid
  # pick, a slate that has kicked off), the expected scores roll back with it.
  # That also makes the dry run honest — it runs the real write and rolls it
  # back, so what it reports is what an apply would do.
  #
  # It REFUSES on schedule drift: a span row whose game is no longer in the
  # weekly slate (or a new game that is). That is a REBUILD, not a refresh, and
  # a rebuild is exactly what the picks guard forbids — so it is the operator's
  # problem, named rather than papered over.
  class RefreshSpanSlate
    Update = Data.define(:team_slug, :week, :old, :new) do
      def delta
        new.to_f - old.to_f
      end
    end

    Result = Data.define(:slate, :updates, :reprice, :refusal, :applied)

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
      sources = source_scores
      drift = drift_for(sources)
      return Result.new(slate: @slate, updates: [], reprice: nil, refusal: drift, applied: false) if drift

      updates = planned_updates(sources)
      reprice = nil

      ActiveRecord::Base.transaction do
        apply_updates!(updates)
        @slate.reload
        reprice = RepriceSpanSlate.call(slate: @slate, apply: true,
                                        reprice_paid_picks: @reprice_paid_picks, now: @now)
        raise ActiveRecord::Rollback unless @apply && reprice.refusal.nil?
      end
      @slate.reload

      Result.new(slate: @slate, updates: updates, reprice: reprice, refusal: reprice.refusal,
                 applied: @apply && reprice.refusal.nil?)
    end

    private

    # { [team_slug, game_slug] => expected_score } from the WEEKLY slates the
    # span was assembled from — the rows `market:snapshot` just refreshed.
    def source_scores
      weeks = @slate.week_range&.to_a || [@slate.week]
      weekly = Slate.where(week: weeks, year: @slate.season_year, sport: @slate.sport,
                           season_type: @slate.season_type)
                    .reject { |slate| slate.week_range.nil? || slate.week_range.size > 1 }

      weekly.flat_map { |slate| slate.slate_matchups.to_a }
            .to_h { |matchup| [[matchup.team_slug, matchup.game_slug], matchup.expected_score] }
    end

    def drift_for(sources)
      span_keys = @slate.slate_matchups.map { |m| [m.team_slug, m.game_slug] }.to_set
      source_keys = sources.keys.to_set
      return "#{@slate.name} has no source weekly slates to read" if source_keys.empty?

      missing = span_keys - source_keys
      return nil if missing.empty?

      "#{missing.size} of this span's games are no longer in the weekly slates " \
        "(#{missing.first(3).map { |team, game| "#{team} in #{game || 'no game'}" }.join(', ')}" \
        "#{'…' if missing.size > 3}) — that is a rebuild, not a refresh"
    end

    def planned_updates(sources)
      @slate.slate_matchups.includes(:team).filter_map do |matchup|
        fresh = sources[[matchup.team_slug, matchup.game_slug]]
        next if fresh.nil? || fresh.to_f == matchup.expected_score.to_f

        Update.new(team_slug: matchup.team_slug, week: matchup.week,
                   old: matchup.expected_score, new: fresh)
      end
    end

    def apply_updates!(updates)
      updates.each do |update|
        @slate.slate_matchups.where(team_slug: update.team_slug, week: update.week)
              .update_all(expected_score: update.new, updated_at: @now)
      end
    end
  end
end
