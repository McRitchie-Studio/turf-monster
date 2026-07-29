require "csv"

module Nfl
  class CacheExpectedTeamTotals
    DEFAULT_YEAR = 2026
    DEFAULT_PATH = Rails.root.join("db/seeds/data/nfl/2026_expected_team_totals.csv")

    Result = Data.define(
      :year,
      :rows,
      :games_created,
      :slates_created,
      :matchups_created,
      :projections_upserted,
      :stale_deleted
    )

    def self.call(...)
      new(...).call
    end

    def self.derive(game_total:, home_spread:)
      total = BigDecimal(game_total.to_s)
      spread = BigDecimal(home_spread.to_s)
      home_points = ((total - spread) / 2).round(2)

      {
        home: home_points,
        away: (total - home_points).round(2)
      }
    end

    def initialize(year: DEFAULT_YEAR, path: DEFAULT_PATH)
      @year = year.to_i
      @path = Pathname(path)
      @touched_projection_ids = []
      @games_created = 0
      @slates_created = 0
      @matchups_created = 0
      @projections_upserted = 0
    end

    def call
      raise ArgumentError, "Missing team totals CSV: #{@path}" unless @path.exist?

      rows = CSV.read(@path, headers: true)
      ActiveRecord::Base.transaction do
        rows.each { |row| cache_row(row) }
        stale_deleted = delete_stale_rows

        Result.new(
          year: @year,
          rows: rows.length,
          games_created: @games_created,
          slates_created: @slates_created,
          matchups_created: @matchups_created,
          projections_upserted: @projections_upserted,
          stale_deleted: stale_deleted
        )
      end
    end

    private

    def cache_row(row)
      week = integer(row.fetch("week"))
      away_team = Team.find_by!(slug: row.fetch("away_team_slug"))
      home_team = Team.find_by!(slug: row.fetch("home_team_slug"))
      favorite_team = Team.find_by!(slug: row.fetch("favorite_team_slug"))
      game = ensure_game!(home_team: home_team, away_team: away_team)
      slate = ensure_slate!(week: week)
      expected = self.class.derive(
        game_total: decimal(row.fetch("game_total")),
        home_spread: home_spread_for(row)
      )

      ensure_matchups!(
        slate: slate,
        game: game,
        home_team: home_team,
        away_team: away_team,
        expected_points_by_team_slug: {
          away_team.slug => expected.fetch(:away),
          home_team.slug => expected.fetch(:home)
        }
      )

      upsert_projection!(
        row: row,
        week: week,
        slate: slate,
        game: game,
        team: away_team,
        opponent_team: home_team,
        favorite_team: favorite_team,
        home: false,
        expected_points: expected.fetch(:away)
      )
      upsert_projection!(
        row: row,
        week: week,
        slate: slate,
        game: game,
        team: home_team,
        opponent_team: away_team,
        favorite_team: favorite_team,
        home: true,
        expected_points: expected.fetch(:home)
      )
    end

    def ensure_game!(home_team:, away_team:)
      slug = "#{home_team.slug}-vs-#{away_team.slug}"
      game = Game.find_or_initialize_by(slug: slug)
      @games_created += 1 if game.new_record?
      game.assign_attributes(
        home_team_slug: home_team.slug,
        away_team_slug: away_team.slug,
        venue: game.venue.presence || home_team.home_arena&.name
      )
      game.status = "scheduled" if game.status.blank?
      game.save!
      game
    end

    def ensure_slate!(week:)
      slate = Slate.find_or_initialize_by(name: "NFL #{@year} Week #{week}")
      @slates_created += 1 if slate.new_record?
      # Record the week as data, not just as a substring of the name — it's what
      # multi-week contests order and validate consecutiveness on. Same for sport and
      # year: written as COLUMNS so no reader has to parse the name back apart. Set on
      # every save (not just create) so a pre-`slates-sport-year` row picks them up the
      # first time this touches it.
      slate.week = week
      slate.sport = "nfl"
      slate.year = @year
      slate.save!
      slate
    end

    def ensure_matchups!(slate:, game:, home_team:, away_team:, expected_points_by_team_slug:)
      [[home_team, away_team], [away_team, home_team]].each do |team, opponent|
        matchup = SlateMatchup.find_or_initialize_by(slate: slate, team_slug: team.slug)
        @matchups_created += 1 if matchup.new_record?
        matchup.assign_attributes(
          week: slate.week,
          opponent_team_slug: opponent.slug,
          game_slug: game.slug,
          dk_goals_expectation: expected_points_by_team_slug.fetch(team.slug).round(1)
        )
        matchup.save!
      end

      rank_slate_matchups!(slate)
    end

    # Rank by TEAM, not by matchup row. A team's standing in the slate is its
    # SUMMED expected points across every game it plays here, so a multi-week
    # slate ranks 32 teams rather than 96 rows.
    #
    # The resulting rank + turf_score are written to EVERY row of that team, so
    # each row still carries the value that prices it. That keeps every existing
    # per-row read working untouched, and it FREEZES the multiplier: it is stored
    # at ingest rather than recomputed on each render, so a pick cannot be
    # repriced under a player after they commit.
    #
    # A one-week slate is the degenerate case — one game per team, so this
    # reduces exactly to the previous per-row ranking.
    def rank_slate_matchups!(slate)
      rankings = slate.team_rankings
      return if rankings.empty?

      slate.slate_matchups.includes(:team).find_each do |matchup|
        ranking = rankings[matchup.team_slug]
        next if ranking.nil?

        matchup.update!(rank: ranking[:rank], turf_score: ranking[:turf_score])
      end
    end

    def upsert_projection!(row:, week:, slate:, game:, team:, opponent_team:, favorite_team:, home:, expected_points:)
      projection = NflTeamTotalProjection.find_or_initialize_by(
        year: @year,
        week: week,
        game_slug: game.slug,
        team_slug: team.slug
      )
      projection.assign_attributes(
        slate: slate,
        opponent_team_slug: opponent_team.slug,
        home: home,
        expected_points: expected_points,
        game_total: decimal(row.fetch("game_total")),
        home_spread: home_spread_for(row),
        favorite_team_slug: favorite_team.slug,
        favorite_spread: decimal(row.fetch("favorite_spread")),
        source: row.fetch("source"),
        source_published_on: row["source_published_on"].presence,
        source_url: row["source_url"].presence,
        source_text: row["source_text"].presence,
        cached_at: Time.current
      )
      projection.save!
      @touched_projection_ids << projection.id
      @projections_upserted += 1
      projection
    end

    def delete_stale_rows
      scope = NflTeamTotalProjection.where(year: @year)
      scope = scope.where.not(id: @touched_projection_ids) if @touched_projection_ids.any?
      scope.delete_all
    end

    def home_spread_for(row)
      favorite_spread = decimal(row.fetch("favorite_spread"))
      favorite_team_slug = row.fetch("favorite_team_slug")
      home_team_slug = row.fetch("home_team_slug")
      away_team_slug = row.fetch("away_team_slug")

      if favorite_team_slug == home_team_slug
        favorite_spread
      elsif favorite_team_slug == away_team_slug
        favorite_spread.abs
      else
        BigDecimal("0")
      end
    end

    def integer(value)
      Integer(value)
    end

    def decimal(value)
      BigDecimal(value.to_s)
    end
  end
end
