require "net/http"
require "json"

module Nfl
  # Snapshots historical NFL regular-season final scores from ESPN's public
  # scoreboard API (the same source as db/seeds/data/nfl_2026_weeks_1_17.json)
  # into a checked-in JSON dataset. Network runs only when the rake task is
  # invoked; everything downstream (Nfl::PointsDistribution) reads the file.
  class FetchHistoricalScores
    DEFAULT_SEASONS = [2023, 2024, 2025].freeze
    DEFAULT_PATH = Rails.root.join("db/seeds/data/nfl/historical_scores_2023_2025.json")
    BASE_URL = "https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard"
    REGULAR_SEASON_TYPE = 2

    Result = Data.define(:seasons, :games, :path)

    def self.call(...)
      new(...).call
    end

    # Pure parse seam: ESPN scoreboard payload -> game rows for one season.
    # Keeps only completed regular-season games belonging to that season, so a
    # wide date-range query can safely catch preseason/postseason spillover.
    # Total by design: any events-less payload parses to [], and it is `call`
    # that decides an empty parse is unacceptable before touching the dataset.
    def self.rows_from(payload, season:)
      (payload["events"] || []).filter_map do |event|
        event_season = event.fetch("season", {})
        next unless event_season["year"] == season
        next unless event_season["type"] == REGULAR_SEASON_TYPE

        competition = event.fetch("competitions").first
        next unless competition.dig("status", "type", "completed")

        competitors = competition.fetch("competitors")
        home = competitors.find { |c| c["homeAway"] == "home" }
        away = competitors.find { |c| c["homeAway"] == "away" }

        {
          "season" => season,
          "week" => event.dig("week", "number"),
          "away" => away.dig("team", "abbreviation"),
          "away_score" => Integer(away.fetch("score")),
          "home" => home.dig("team", "abbreviation"),
          "home_score" => Integer(home.fetch("score"))
        }
      end
    end

    def initialize(seasons: DEFAULT_SEASONS, path: DEFAULT_PATH)
      @seasons = seasons.map { |season| Integer(season) }
      raise ArgumentError, "at least one season is required" if @seasons.empty?

      @path = Pathname(path)
    end

    # Replaces the checked-in dataset only when EVERY requested season
    # contributed completed regular-season games. A 200 carrying no usable
    # events is a failed fetch, not an empty season: without this guard it
    # writes "games": [] straight over the dataset it was meant to refresh.
    def call
      games = @seasons.flat_map do |season|
        rows = self.class.rows_from(fetch_season(season), season: season)
        raise "ESPN scoreboard returned no completed regular-season games for season #{season}" if rows.empty?

        rows
      end
      games.sort_by! { |g| [g.fetch("season"), g.fetch("week"), g.fetch("home")] }

      @path.dirname.mkpath
      @path.write(JSON.pretty_generate(
        "source" => BASE_URL,
        "generated_at" => Date.current.iso8601,
        "seasons" => @seasons,
        "games" => games
      ) + "\n")

      Result.new(seasons: @seasons, games: games.length, path: @path)
    end

    private

    # One wide date-range request per season; rows_from filters the spillover.
    def fetch_season(season)
      uri = URI("#{BASE_URL}?dates=#{season}0901-#{season + 1}0201&limit=400")
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
        http.get(uri.request_uri)
      end
      raise "ESPN scoreboard request failed (#{response.code}) for season #{season}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    end
  end
end
