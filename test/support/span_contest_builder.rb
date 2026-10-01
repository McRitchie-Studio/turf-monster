# Builds a two-week SPAN slate over the six fixture teams and points a contest at
# it: twelve SlateMatchup rows, two per team, each on a real Game with a kickoff.
#
# The kickoffs matter. Contest#pickable_matchups is each team's FIRST game by
# kickoff, and SlateMatchup#locked? reads the row's own game, so a builder
# without games could not tell a week-one row from a week-two row and could not
# show the later row staying unlocked after the team has already played.
module SpanContestBuilder
  SPAN_PAIRINGS = {
    1 => [ %w[team-a team-b], %w[team-c team-d], %w[team-e team-f] ],
    2 => [ %w[team-a team-c], %w[team-b team-e], %w[team-d team-f] ]
  }.freeze

  # Returns the contest, now multi-week. `week_one_kickoff` / `week_two_kickoff`
  # let a test put week one in the past.
  def build_span_contest!(contest, week_one_kickoff: 3.days.from_now, week_two_kickoff: 10.days.from_now)
    slate = Slate.create!(name: "NFL 2026 Weeks 1-2 #{SecureRandom.hex(3)}", week: 1)
    kickoffs = { 1 => week_one_kickoff, 2 => week_two_kickoff }

    SPAN_PAIRINGS.each do |week, pairs|
      pairs.each do |home, away|
        game = Game.create!(home_team_slug: home, away_team_slug: away, kickoff_at: kickoffs[week], week: week)
        [ [ home, away ], [ away, home ] ].each do |team, opponent|
          SlateMatchup.create!(slate: slate, team_slug: team, opponent_team_slug: opponent,
                               game_slug: game.slug, week: week, expected_score: 20.0,
                               turf_score: 2.0, rank: 1, status: "pending")
        end
      end
    end

    contest.update!(slate: slate)
    contest
  end

  # The team's row for one week of the span.
  def span_row(contest, team_slug, week:)
    contest.matchups.find_by!(team_slug: team_slug, week: week)
  end
end
