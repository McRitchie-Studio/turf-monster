# The slate-derived facts about a PAGE of contests, in two grouped queries.
#
# Why this exists instead of calling the model: Contest#picks_required,
# #multi_week?, #locks_at, #locked? and #live? each go back to the slate, and
# each trip is one to four queries (Slate#matchups_by_team loads every matchup
# with its team, opponent and game). Called per row on GET /api/v1/contests that
# is a few hundred queries for one page. Here the same answers come from row
# counts per (slate, team) and, only for contests with no starts_at, the first
# and last kickoff per slate.
#
# THE RULES ARE THE MODEL'S, NOT A SECOND COPY TO DRIFT. Each method names the
# Contest method it mirrors, and test/serializers/api/v1/contest_facts_test.rb
# asserts the two agree on a single-week slate, a span slate, a span slate
# with fewer than six teams, a slate with a bye, an empty slate, a contest with
# no starts_at and a retired-format contest with no slate.
# Change a rule in Contest and that test is what tells you to change it here.
#
# Callers must load contests with `includes(:slate)`.
module Api
  module V1
    class ContestFacts
      def self.for(contests, now: Time.current)
        new(Array(contests), now: now)
      end

      def initialize(contests, now:)
        @now = now
        slate_ids = contests.filter_map(&:slate_id).uniq
        games_per_team = slate_ids.empty? ? {} : SlateMatchup.where(slate_id: slate_ids).group(:slate_id, :team_slug).count

        @teams = Hash.new(0)
        @max_games = Hash.new(0)
        games_per_team.each do |(slate_id, _team_slug), games|
          @teams[slate_id] += 1
          @max_games[slate_id] = games if games > @max_games[slate_id]
        end

        unscheduled = contests.select { |contest| contest.starts_at.nil? }.filter_map(&:slate_id).uniq
        @kickoffs = kickoff_bounds(unscheduled)
      end

      # Contest#picks_required (Contest.picks_required_for_slate). It counts
      # TEAMS, capped at six: a pick is a team, and a span slate holds several
      # rows per team, so a four-team span asks for four, not six.
      def picks_required(contest)
        teams = @teams[contest.slate_id]
        return Contest::TURF_TOTALS_DEFAULT_PICKS_REQUIRED if teams.zero?

        [teams, Contest::TURF_TOTALS_DEFAULT_PICKS_REQUIRED].min
      end

      # Contest#weeks_count (Slate#games_per_team): the most games any one team
      # plays in this contest.
      def games_per_team(contest)
        @max_games[contest.slate_id]
      end

      # Contest#multi_week? (Slate#multi_game_per_team?).
      def multi_week?(contest)
        games_per_team(contest) > 1
      end

      # Contest#locks_at: the stated lock, else the slate's default
      # (Slate#default_contest_lock_at) — the same Contest::LockRule, fed the
      # first and last kickoff from one grouped query instead of per slate.
      def locks_at(contest)
        return contest.starts_at if contest.starts_at

        first, last = @kickoffs[contest.slate_id]
        slate = contest.slate
        Contest::LockRule.default_lock_at(sport: slate&.sport, first_kickoff: first,
                                          last_kickoff: last, fallback: slate&.starts_at)
      end

      # Contest#locked?
      def locked?(contest)
        return true if contest.settled?

        at = locks_at(contest)
        at.present? && @now >= at
      end

      # Contest#live?
      def live?(contest)
        locked?(contest) && !contest.settled?
      end

      # One word for where the contest is in its life. `open` takes entries (see
      # accepting_entries for the rest of that question), `live` is locked with
      # games being played, `settled` is graded and final. A cancelled contest
      # keeps whichever of these it had and is flagged separately.
      def phase(contest)
        return "settled" if contest.settled?

        locked?(contest) ? "live" : "open"
      end

      private

      # { slate_id => [first kickoff, last kickoff] }
      def kickoff_bounds(slate_ids)
        return {} if slate_ids.empty?

        SlateMatchup.joins(:game)
                    .where(slate_id: slate_ids)
                    .where.not(games: { kickoff_at: nil })
                    .group(:slate_id)
                    .pluck(:slate_id, Arel.sql("MIN(games.kickoff_at)"), Arel.sql("MAX(games.kickoff_at)"))
                    .to_h { |slate_id, first, last| [slate_id, [as_time(first), as_time(last)]] }
      end

      def as_time(value)
        value.is_a?(String) ? Time.zone.parse(value) : value&.in_time_zone
      end
    end
  end
end
