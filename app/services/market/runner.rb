module Market
  # The command-line half of market:pull / market:refresh: reads the run's
  # arguments out of the environment and prints what the services did.
  #
  # It lives here rather than inline in the rake file so both tasks report the
  # same way and so the reporting is testable — a rake body is reachable only by
  # invoking the task, which is how a printed refusal ends up unread and
  # untested.
  module Runner
    DEFAULT_YEAR = Nfl::CacheExpectedTeamTotals::DEFAULT_YEAR

    class << self
      def year
        Integer(ENV.fetch("YEAR", DEFAULT_YEAR))
      end

      # WEEKS=4,5,6 — the weeks to pull. Refuses rather than defaulting to the
      # whole season: a season-wide pull re-ranks every week the dataset covers
      # (docs/workflows/market-snapshot.md), which is never what a benchmark
      # rebuild wants.
      def weeks
        list = ENV["WEEKS"].to_s.split(",").map(&:strip).reject(&:empty?)
        abort "set WEEKS=<comma-separated weeks>, e.g. WEEKS=4,5,6" if list.empty?

        list.map { |week| Integer(week) }.uniq.sort
      end

      def pull(apply:)
        Nfl::FetchMarketLines.call(
          year: year,
          weeks: weeks,
          path: ENV["CSV_PATH"].presence || Nfl::FetchMarketLines::DEFAULT_PATH,
          apply: apply,
          allow_schedule_change: ENV["ALLOW_SCHEDULE_CHANGE"] == "1"
        )
      end

      def print_pull(result)
        puts "    #{result.rows} games across weeks #{result.weeks.join(', ')} · source #{result.source}"
        if result.changes.empty?
          puts "    no line moves — the dataset already matches DraftKings"
        else
          result.changes.group_by(&:week).each do |week, changes|
            puts "    week #{week}: #{changes.size} line move(s)"
            changes.each do |change|
              puts format("      %-24s %-8s %s -> %s", "#{change.away_team_slug} at #{change.home_team_slug}",
                          change.field, change.old, change.new)
            end
          end
        end
        result.gaps.each { |gap| puts "    GAP week #{gap.week} #{gap.matchup}: #{gap.reason}" }
        result.drift.each { |line| puts "    DRIFT #{line}" }
      end

      def print_refresh(result)
        puts "    #{result.updates.size} expected score(s) change"
        result.updates.first(10).each do |update|
          puts format("      %-24s week %-3s %s -> %s", update.team_slug, update.week, update.old, update.new)
        end
        puts "      …#{result.updates.size - 10} more" if result.updates.size > 10
        return if result.reprice.nil?

        changed = result.reprice.changed
        puts "    #{changed.size} of #{result.reprice.changes.size} teams change price" \
             " · #{result.reprice.paid_picks} paid pick(s) on this slate"
        changed.each do |change|
          puts format("      %-24s #%-3s %sx -> #%-3s %sx%s", change.team_slug,
                      change.old_rank || "-", change.old_turf_score || "-",
                      change.new_rank, change.new_turf_score,
                      change.game_factor > 1 ? "  (#{change.games} games, bye line)" : "")
        end
      end
    end
  end
end
