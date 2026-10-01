# One contest's team board, loaded once and read many times.
#
# Slate#matchups_by_team is the single load (every matchup with its team,
# opponent and game). The contest detail reads its pickable rows from here, and
# every pick on an entry or a leaderboard row reads its team's games from here,
# so rendering a hundred entries of six picks costs no query past this one.
#
# WHICH ROWS ARE PICKABLE is not decided here. Contest#pickable_matchup_ids is
# the list both pick writers and the confirm gate check a row against; this
# class only filters the loaded rows by it.
#
# THE SCORE COLUMN IS CALLED `goals` AND IS NOT ALWAYS GOALS. On an NFL slate
# slate_matchups.goals holds points. The JSON says `team_score`, and the contest
# carries `scoring_unit` ("goals" or "points") to say which.
module Api
  module V1
    class Board
      attr_reader :contest

      def initialize(contest, contest_locked:)
        @contest = contest
        @contest_locked = contest_locked
        @by_team = contest.matchups_by_team
        @rows_by_id = @by_team.values.flatten.index_by(&:id)
        @span_weeks = @rows_by_id.values.filter_map(&:week).uniq.sort
      end

      # The teams a player may pick, best offense (rank 1) first.
      def teams
        pickable_ids = contest.pickable_matchup_ids.to_set
        @rows_by_id.values
                   .select { |matchup| pickable_ids.include?(matchup.id) }
                   .sort_by { |matchup| [matchup.rank || Float::INFINITY, matchup.team.name] }
                   .map { |matchup| team_row(matchup) }
      end

      # One pick on an entry: the team row plus what the pick has earned.
      def pick(selection)
        matchup = @rows_by_id[selection.slate_matchup_id] || selection.slate_matchup
        team_row(matchup).merge(points: selection.points&.to_f)
      end

      private

      def team_row(matchup)
        games = @by_team[matchup.team_slug] || [matchup]
        {
          matchup_id: matchup.id,
          team: team_json(matchup.team),
          rank: matchup.rank,
          turf_score: matchup.turf_score&.to_f,
          expected_team_score: expected_team_score(games),
          team_score: team_score(games),
          locked: @contest_locked || matchup.locked?,
          games_count: games.size,
          bye_weeks: @span_weeks - games.filter_map(&:week),
          games: games.map { |game_matchup| game_json(game_matchup) }
        }
      end

      # Summed over the team's games, as Slate#expected_points_by_team does.
      # nil when no game carries a projection (World Cup slates carry none).
      def expected_team_score(games)
        projected = games.select { |matchup| matchup.expected_score.present? }
        return nil if projected.empty?

        projected.sum { |matchup| matchup.expected_score.to_f }.round(1)
      end

      # What the team has scored across the games with a result, the same set
      # Selection#compute_points! multiplies. nil until one game has a result,
      # which is not the same statement as zero.
      def team_score(games)
        scored = games.select { |matchup| matchup.goals.present? }
        return nil if scored.empty?

        scored.sum(&:goals)
      end

      def game_json(matchup)
        game = matchup.game
        {
          week: matchup.week,
          opponent: team_json(matchup.opponent_team),
          home: game ? game.home_team_slug == matchup.team_slug : nil,
          kickoff_at: game&.kickoff_at&.iso8601,
          status: game&.status,
          started: matchup.locked?,
          final: game&.status == "completed",
          team_score: matchup.goals
        }
      end

      def team_json(team)
        return nil unless team

        { slug: team.slug, name: team.name, short_name: team.short_name }
      end
    end
  end
end
