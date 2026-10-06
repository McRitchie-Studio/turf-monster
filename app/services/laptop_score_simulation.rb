# A SIMULATED game for the /turf-monster-v2 hero laptop: the featured game of
# the live snapshot, played out in memory so the laptop can show what
# /contests/<slug>/live does when a touchdown lands.
#
# It opens at away 3, home 7 (a field goal for the away side, a touchdown and
# extra point for the home side), then alternates touchdowns, away first:
# 10-7, 10-14, 17-14, 17-21, 24-21, 24-28, and STOPS at the touchdown that
# takes the combined score to STOP_AT (50) or past it: the
# page holds that final frame and never loops back to 3-7.
#
# NOTHING HERE IS WRITTEN. Every Game is a fresh in-memory copy of the real one
# and every Goal is a new record, all marked readonly!, so a save anywhere in
# the render path raises instead of writing. The real Game row, the contest's
# matchups and its leaderboard are never touched; the laptop's leaderboard
# keeps its real numbers.
#
# NO LABEL ON THE LAPTOP: no "Simulated preview" badge. The scores are still
# never written anywhere.
class LaptopScoreSimulation
  INTERVAL_MS = 10_000
  OPENING = { away: 3, home: 7 }.freeze
  TOUCHDOWN_POINTS = 7
  STOP_AT = 50
  # How many touchdowns it takes to reach STOP_AT from the opening's 10:
  # 10 + 6 * 7 = 52, the first total at or past 50.
  TOUCHDOWNS = ((STOP_AT - OPENING.values.sum).to_f / TOUCHDOWN_POINTS).ceil

  # The game clock per frame: the opening score, then one per touchdown. A
  # clock that stood still while six touchdowns were scored would read as a
  # broken page rather than a game.
  CLOCKS = [[1, "4:12"], [2, "9:48"], [2, "1:05"], [3, "7:30"], [3, "0:41"], [4, "10:02"], [4, "2:37"]].freeze

  # One state of the game. `goal` is the touchdown that produced it (nil on
  # the opening frame), `team` the side that scored it.
  Frame = Data.define(:index, :game, :goal, :team)

  attr_reader :source

  def initialize(game)
    @source = game
  end

  def opening = frames.first

  def frames
    @frames ||= build_frames
  end

  private

  def build_frames
    away = @source.away_team
    home = @source.home_team
    goals = [goal(away, "field_goal", 3), goal(home, "touchdown", TOUCHDOWN_POINTS)]
    score = OPENING.dup
    list = [frame(0, score, goals, nil, nil, next_scorer: away)]

    TOUCHDOWNS.times do |i|
      side = i.even? ? :away : :home
      team = side == :away ? away : home
      td = goal(team, "touchdown", TOUCHDOWN_POINTS)
      goals += [td]
      score = score.merge(side => score[side] + TOUCHDOWN_POINTS)
      list << frame(i + 1, score, goals, td, team, next_scorer: side == :away ? home : away)
    end
    list
  end

  def frame(index, score, goals, goal, team, next_scorer:)
    Frame.new(index: index, game: simulated_game(index, score, goals, next_scorer), goal: goal, team: team)
  end

  # A copy, never the record: assigning to the real Game would leave it dirty
  # for anything else on the request that reads it.
  def simulated_game(index, score, goals, next_scorer)
    period, clock = CLOCKS.fetch(index) { CLOCKS.last }
    game = Game.new(@source.attributes)
    game.assign_attributes(
      away_score: score[:away], home_score: score[:home],
      status: "in_progress", period: period, clock: clock,
      status_detail: "#{clock} - #{period.ordinalize}",
      # The ball with the side that scores next, at its own 25 after the
      # kickoff, so the field bar moves from frame to frame.
      possession_team_slug: next_scorer&.slug,
      possession_text: next_scorer&.short_name.present? ? "#{next_scorer.short_name} 25" : nil,
      down_distance: "1st & 10"
    )
    game.association(:home_team).target = @source.home_team
    game.association(:away_team).target = @source.away_team
    goals_assoc = game.association(:goals)
    goals_assoc.target = goals
    goals_assoc.loaded!
    game.readonly!
    game
  end

  # Ids only order the rail (Live::RailFeed sorts goals by id, newest first);
  # the record is new and readonly, so the id never reaches the database.
  def goal(team, scoring_type, points)
    @next_goal_id = (@next_goal_id || 0) + 1
    Goal.new(id: @next_goal_id, game_slug: @source.slug, team_slug: team&.slug,
             scoring_type: scoring_type, points: points).tap do |goal|
      goal.association(:team).target = team
      goal.readonly!
    end
  end
end
