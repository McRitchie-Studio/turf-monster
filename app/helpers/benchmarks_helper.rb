module BenchmarksHelper
  # The pricing curve as plottable points.
  #
  # Every y here is `SlateMatchup.turf_score_for` — the SAME call that prices the
  # board, rounded the same way. The chart is therefore a picture OF the rule
  # rather than a second drawing of it: re-tune the curve and the line moves with
  # the table beneath it. A hand-plotted 1.0→2.0 straight line would have been
  # smoother and would have started lying the first time the curve changed.
  #
  # It is a staircase, not a ramp, and that is honest: the curve rounds to one
  # decimal, so ranks 1 and 2 really do both price at x1.0.
  CurvePoint = Data.define(:rank, :turf_score)

  def turf_score_curve(teams:, sport:, game_factor: 1.0)
    return [] if teams.to_i < 1

    (1..teams.to_i).map do |rank|
      CurvePoint.new(
        rank: rank,
        turf_score: SlateMatchup.turf_score_for(rank, teams, sport: sport, game_factor: game_factor)
      )
    end
  end

  # The slate's own lines: the full-span one every slate has, plus the bye line
  # when some team plays short. Each carries the label the legend and the
  # direct label both read, so they can never disagree.
  Line = Data.define(:key, :label, :points, :game_factor)

  def benchmark_lines(slate, teams)
    span = slate.games_per_team
    full = Line.new(key: "full", label: pluralize(span, "game"), game_factor: 1.0,
                    points: turf_score_curve(teams: teams, sport: slate.sport))
    return [full] unless slate.two_line_pricing?

    factor = Slate.game_factor(span, span - 1)
    [full, Line.new(key: "bye", label: "#{span - 1} games · bye", game_factor: factor,
                    points: turf_score_curve(teams: teams, sport: slate.sport, game_factor: factor))]
  end
end
