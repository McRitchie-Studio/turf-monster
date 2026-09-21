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

  # The frame never shrinks past the range every slate shares: rank 1 prices at
  # x1.0 and a full-span board runs to x2.0, so a flat slate still reads as a
  # flat line against a familiar scale instead of filling the box with noise.
  DEFAULT_FLOOR = 1.0
  DEFAULT_CEILING = 2.0

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

  # The chart's y range, as [min, max] — sized to the DOTS as well as the lines.
  #
  # That is the whole point of the dots. The lines are the rule, but each dot is
  # a team's STORED multiplier, hand-written from the admin board. Sized to the
  # lines alone, a hand-edited 3.5x on a slate whose bye line tops at 3.0x
  # mapped ABOVE the viewBox and an SVG clipped it away, so the largest
  # mispricings were exactly the marks the picture dropped.
  #
  # THE WRITE IS BOUNDED NOW, AND THAT DOES NOT RETIRE THIS. Since
  # bound-admin-turf-score, SlatesController#update_turf_scores refuses a price
  # outside SlateMatchup.price_band. But that band is deliberately the widest
  # price this slate's BOARD can display, not the widest its lines reach — x1.0
  # up to the top of the scale slider — so x3.5 on a bye line topping at x3.0
  # is still accepted, on purpose, and still lands outside the frame the lines
  # would draw. Both ends remain reachable: the band floors at x1.0, while the
  # bye line starts at x1.5, so a bye team stored at x1.0 sits under its line.
  #
  # A dot sitting ON its line never moves the frame, so an ordinary slate draws
  # the chart it always drew. Only one that OUTRUNS its line does, and it takes
  # a tenth of air with it so it reads as a value rather than as ink on the
  # border. The air is worked in whole tenths because the stored price is
  # rounded to one decimal and 0.6 minus 0.1 is 0.49999999999999994 in binary
  # floating point — which floors to 0.4 and relabels the entire axis.
  def benchmark_y_domain(lines:, team_rows:)
    curve = lines.flat_map { |line| line.points.map(&:turf_score) }
    return [DEFAULT_FLOOR, DEFAULT_CEILING] if curve.empty?

    dots = team_rows.filter_map { |row| row.turf_score&.to_f }
    under = dots.select { |dot| dot < curve.min }.min
    over = dots.select { |dot| dot > curve.max }.max

    [
      [under ? ((under * 10).round - 1) / 10.0 : curve.min.floor(1), DEFAULT_FLOOR].min,
      [over ? ((over * 10).round + 1) / 10.0 : curve.max.ceil(1), DEFAULT_CEILING].max
    ]
  end
end
