require "json"

module Nfl
  # The NFL analog of the World Cup goals-distribution model
  # (SlateMatchup.goals_distribution_for): review past games to learn what
  # scoring to expect from each of the 32 teams in a given week, by rank.
  #
  # From the checked-in historical dataset it keeps only FULL weeks — weeks
  # where every team played (no byes) — so each week yields one clean sample
  # of 32 team scores. Each week's scores are ranked 1..32 (highest first),
  # actual points are averaged per rank across all full weeks, and two curve
  # families are least-squares fitted to the rank means:
  #
  #   log:    expected_points(rank) = base + scale * ln(n / rank) / ln(n)
  #   linear: expected_points(rank) = base + scale * (n - rank) / (n - 1)
  #
  # The log family is the World Cup goals curve (base 0.2, scale 4.3), kept
  # for cross-sport comparison. Both bases share one meaning: base is the
  # rank-n expectation and base + scale the rank-1 expectation.
  class PointsDistribution
    DEFAULT_PATH = Rails.root.join("db/seeds/data/nfl/historical_scores_2023_2025.json")
    TEAM_COUNT = 32

    BASIS = {
      log: ->(rank, n) { Math.log(n.to_f / rank) / Math.log(n) },
      linear: ->(rank, n) { (n - rank).to_f / (n - 1) }
    }.freeze

    Fit = Data.define(:kind, :base, :scale, :r_squared, :rmse) do
      def expected_points_for(rank, n = TEAM_COUNT)
        (base + scale * BASIS.fetch(kind).call(rank, n)).round(2)
      end

      def formula(n = TEAM_COUNT)
        basis = kind == :log ? "ln(#{n}/rank)/ln(#{n})" : "(#{n}-rank)/#{n - 1}"
        "#{base} + #{scale} * #{basis}"
      end
    end

    Result = Data.define(
      :seasons,
      :team_count,
      :full_weeks,
      :partial_weeks_skipped,
      :games_analyzed,
      :mean_points,
      :expected_points_by_rank,
      :fits
    ) do
      def best_fit
        fits.values.max_by(&:r_squared)
      end

      def expected_points_for(rank, n = nil)
        best_fit.expected_points_for(rank, n || team_count)
      end
    end

    def self.call(...)
      new(...).call
    end

    # team_count is parameterized for tests (a 4-team synthetic league); real
    # use is always the 32-team NFL.
    def initialize(path: DEFAULT_PATH, team_count: TEAM_COUNT)
      @path = Pathname(path)
      @team_count = team_count
    end

    def call
      raise ArgumentError, "Missing historical scores dataset: #{@path}" unless @path.exist?

      dataset = JSON.parse(@path.read)
      games_by_week = dataset.fetch("games").group_by { |g| [g.fetch("season"), g.fetch("week")] }

      full_weeks, partial_weeks = games_by_week.partition { |_key, games| full_week?(games) }
      raise ArgumentError, "No full weeks (all #{@team_count} teams playing) in #{@path}" if full_weeks.empty?

      scores_by_rank = Array.new(@team_count) { [] }
      full_weeks.each do |_key, games|
        week_scores(games).each_with_index { |points, index| scores_by_rank[index] << points }
      end

      expected_points_by_rank = scores_by_rank.map { |scores| (scores.sum.to_f / scores.length).round(2) }

      Result.new(
        seasons: dataset.fetch("seasons"),
        team_count: @team_count,
        full_weeks: full_weeks.map(&:first).sort,
        partial_weeks_skipped: partial_weeks.length,
        games_analyzed: full_weeks.sum { |_key, games| games.length },
        mean_points: (expected_points_by_rank.sum / @team_count).round(2),
        expected_points_by_rank: expected_points_by_rank,
        fits: BASIS.keys.index_with { |kind| fit_curve(kind, expected_points_by_rank) }
      )
    end

    private

    # A full week: every team plays exactly once — team_count distinct teams
    # across team_count / 2 games. Bye weeks fail this and are skipped.
    def full_week?(games)
      teams = games.flat_map { |g| [g.fetch("home"), g.fetch("away")] }
      games.length == @team_count / 2 && teams.uniq.length == @team_count
    end

    # One week's team scores, highest first — index i is rank i+1.
    def week_scores(games)
      games.flat_map { |g| [g.fetch("home_score"), g.fetch("away_score")] }.sort.reverse
    end

    def fit_curve(kind, rank_means)
      n = rank_means.length
      xs = (1..n).map { |rank| BASIS.fetch(kind).call(rank, n) }
      ys = rank_means

      x_mean = xs.sum / n
      y_mean = ys.sum.to_f / n
      covariance = xs.zip(ys).sum { |x, y| (x - x_mean) * (y - y_mean) }
      x_variance = xs.sum { |x| (x - x_mean)**2 }

      scale = covariance / x_variance
      base = y_mean - scale * x_mean

      residuals = xs.zip(ys).map { |x, y| y - (base + scale * x) }
      ss_residual = residuals.sum { |r| r**2 }
      ss_total = ys.sum { |y| (y - y_mean)**2 }

      Fit.new(
        kind: kind,
        base: base.round(2),
        scale: scale.round(2),
        r_squared: ss_total.zero? ? 1.0 : (1 - ss_residual / ss_total).round(4),
        rmse: Math.sqrt(ss_residual / n).round(2)
      )
    end
  end
end
