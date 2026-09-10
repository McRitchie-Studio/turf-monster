require "json"

module Soccer
  # Seed-time cache of the 2026 World Cup DraftKings team-total odds — the
  # soccer analog of Nfl::CacheExpectedTeamTotals. Reads the checked-in
  # group-stage scrape (produced by scripts/scrape_draftkings.js) and writes
  # each row's O/U line + American odds onto the matching fifa-slate
  # matchups, so a plain db:seed yields a formula report with live samples.
  class CacheTeamTotalOdds
    DEFAULT_PATH = Rails.root.join("db/seeds/data/soccer/dk_team_totals_2026_group_stage.json")

    Result = Data.define(:rows, :matchups_updated, :teams_missing)

    def self.call(...)
      new(...).call
    end

    def initialize(path: DEFAULT_PATH)
      @path = Pathname(path)
    end

    def call
      raise ArgumentError, "Missing DK team totals dataset: #{@path}" unless @path.exist?

      rows = JSON.parse(@path.read)
      matchups_updated = 0
      teams_missing = []

      ActiveRecord::Base.transaction do
        rows.each do |row|
          team = Team.find_by(short_name: row.fetch("short_name"))
          opponent = Team.find_by(short_name: row.fetch("opponent_short_name"))
          if team.nil? || opponent.nil?
            teams_missing << row.fetch("short_name")
            next
          end

          matchups = SlateMatchup
                     .where(team_slug: team.slug, opponent_team_slug: opponent.slug)
                     .select { |m| m.slate.sport == "fifa" }

          matchups.each do |matchup|
            matchup.update!(
              team_total_over_odds: Integer(row.fetch("over_odds")),
              team_total_under_odds: Integer(row.fetch("under_odds")),
              # The O/U line IS the DK goals expectation; only fill blanks so
              # a hand-tuned expectation is never clobbered by a reseed.
              expected_score: matchup.expected_score || BigDecimal(row.fetch("line").to_s)
            )
            matchups_updated += 1
          end
        end
      end

      Result.new(rows: rows.length, matchups_updated: matchups_updated, teams_missing: teams_missing.uniq)
    end
  end
end
