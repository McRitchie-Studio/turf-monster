require "csv"

module Nfl
  # Pulls DraftKings' lines for whole NFL weeks and writes them into the
  # checked-in seed dataset — step 1 of docs/workflows/market-snapshot.md, the
  # step that was 🔨 PLANNED for the NFL and hand-transcribed until now.
  #
  # The source is ESPN's public scoreboard, which carries DK's own numbers
  # (Nfl::Espn::MarketLines says why, and why not DK directly). Primitives only,
  # so every row it writes is basis "derived".
  #
  # DRY RUN BY DEFAULT: `call` fetches, compares and reports; nothing reaches
  # disk unless `apply: true`. It writes a FILE, not the database — the ingest
  # (`market:snapshot`) is a separate step on purpose, so a market pull can
  # never silently re-price a contest. The file is checked in, so the diff is
  # reviewable before it is ingested.
  #
  # It REFUSES rather than writing a partial week:
  #   * a game with no readable DraftKings line (no odds, no favorite, no total)
  #   * a team abbreviation that maps to no Team row
  #   * SCHEDULE DRIFT — the week's set of matchups no longer matches the
  #     dataset's. A moved game changes which games a slate holds, and that is a
  #     slate REBUILD, which Nfl::BuildSpanSlate refuses once picks exist. Pass
  #     `allow_schedule_change: true` to write anyway, having decided what to do
  #     about the slate.
  class FetchMarketLines
    class Error < StandardError; end

    DEFAULT_PATH = Nfl::CacheExpectedTeamTotals::DEFAULT_PATH
    SEASON_TYPE = 2 # ESPN's regular season, the same scale Slate uses

    Change = Data.define(:week, :away_team_slug, :home_team_slug, :field, :old, :new)
    Gap = Data.define(:week, :matchup, :reason)
    Result = Data.define(:year, :weeks, :rows, :changes, :gaps, :drift, :refusal, :applied, :path, :source)

    def self.call(...)
      new(...).call
    end

    def initialize(year:, weeks:, path: DEFAULT_PATH, apply: false,
                   allow_schedule_change: false, client: Nfl::Espn::Client, today: Date.current)
      @year = year.to_i
      @weeks = Array(weeks).map { |week| Integer(week) }.uniq.sort
      @path = Pathname(path)
      @apply = apply
      @allow_schedule_change = allow_schedule_change
      @client = client
      @today = today
    end

    def call
      raise Error, "Need at least one week" if @weeks.empty?
      raise Error, "Missing team totals CSV: #{@path}" unless @path.exist?

      table = CSV.read(@path, headers: true)
      fetched = @weeks.to_h { |week| [week, fetch_week(week)] }
      gaps = fetched.flat_map { |week, rows| gaps_in(week, rows) }
      drift = fetched.flat_map { |week, rows| drift_in(table, week, rows) }
      changes = fetched.flat_map { |week, rows| changes_in(table, week, rows) }

      result = Result.new(year: @year, weeks: @weeks, rows: fetched.values.sum(&:size),
                          changes: changes, gaps: gaps, drift: drift,
                          refusal: refusal_for(gaps, drift), applied: false,
                          path: @path, source: source_name)
      return result if result.refusal || !@apply

      write!(table, fetched)
      result.with(applied: true)
    end

    private

    # A gap is fatal always; drift is fatal unless the caller has decided what
    # to do about the slate behind it.
    def refusal_for(gaps, drift)
      if gaps.any?
        "#{gaps.size} game(s) carry no readable DraftKings line — " \
          "#{gaps.map { |gap| "week #{gap.week} #{gap.matchup}: #{gap.reason}" }.join('; ')}"
      elsif drift.any? && !@allow_schedule_change
        "the schedule moved since this dataset was written: #{drift.join('; ')}"
      end
    end

    def fetch_week(week)
      payload = @client.scoreboard(year: @year, season_type: SEASON_TYPE, week: week)
      rows = Nfl::Espn::MarketLines.rows_from(payload)
      raise Error, "ESPN returned no games for #{@year} week #{week}" if rows.empty?

      rows
    end

    def gaps_in(week, rows)
      rows.filter_map do |row|
        reason = if !row.complete?
          "no readable DraftKings line (#{row.detail.inspect})"
        elsif team_slug(row.away_abbr).nil?
          "unknown team #{row.away_abbr}"
        elsif team_slug(row.home_abbr).nil?
          "unknown team #{row.home_abbr}"
        elsif team_slug(row.favorite_abbr).nil?
          "unknown favorite #{row.favorite_abbr}"
        end
        Gap.new(week: week, matchup: row.matchup, reason: reason) if reason
      end
    end

    # The week's matchups, compared BOTH directions. A 0-discrepancy match is
    # what licenses replacing the week's rows in place rather than rebuilding
    # the slate behind them.
    def drift_in(table, week, rows)
      return [] if gaps_in(week, rows).any?

      fetched = rows.map { |row| [team_slug(row.away_abbr), team_slug(row.home_abbr)] }.to_set
      known = week_rows(table, week).map { |row| [row["away_team_slug"], row["home_team_slug"]] }.to_set
      return [] if known.empty? || fetched == known

      added = (fetched - known).map { |away, home| "week #{week} adds #{away} at #{home}" }
      removed = (known - fetched).map { |away, home| "week #{week} drops #{away} at #{home}" }
      added + removed
    end

    def changes_in(table, week, rows)
      return [] if gaps_in(week, rows).any?

      known = week_rows(table, week).index_by { |row| [row["away_team_slug"], row["home_team_slug"]] }
      rows.flat_map do |row|
        away = team_slug(row.away_abbr)
        home = team_slug(row.home_abbr)
        before = known[[away, home]]
        next [] if before.nil?

        [
          change_for(week, away, home, "favorite", before["favorite_team_slug"], team_slug(row.favorite_abbr)),
          change_for(week, away, home, "spread", before["favorite_spread"].to_f, row.favorite_spread),
          change_for(week, away, home, "total", before["game_total"].to_f, row.game_total)
        ].compact
      end
    end

    def change_for(week, away, home, field, old, new)
      return nil if old == new

      Change.new(week: week, away_team_slug: away, home_team_slug: home, field: field, old: old, new: new)
    end

    def week_rows(table, week)
      table.select { |row| row["week"].to_i == week }
    end

    def team_slug(abbreviation)
      @team_slugs ||= {}
      @team_slugs[abbreviation] ||= Nfl::Espn::TeamMap.team_for(abbreviation)&.slug
    end

    # Rewrites the dataset with the fetched weeks replaced and every other week
    # kept verbatim — same header, same column order, rows sorted by week then
    # away team, which is the order the file already carries.
    def write!(table, fetched)
      kept = table.reject { |row| @weeks.include?(row["week"].to_i) }
      built = fetched.flat_map do |week, rows|
        known = week_rows(table, week).index_by { |row| [row["away_team_slug"], row["home_team_slug"]] }
        rows.map do |row|
          before = known[[team_slug(row.away_abbr), team_slug(row.home_abbr)]]
          csv_row(table.headers, week, row, before)
        end
      end
      all = (kept.map { |row| table.headers.map { |header| row[header] } } + built)
            .sort_by { |values| [values[0].to_i, values[1].to_s] }

      CSV.open(@path, "w") do |csv|
        csv << table.headers
        all.each { |values| csv << values }
      end
    end

    # A row whose line has not MOVED is written back verbatim, source stamp and
    # all. Re-stamping every row with today's date on every pull would make the
    # dataset's diff 45 rows deep when two games moved, burying the change a
    # reviewer is there to see — and the old stamp is not stale, it is the day
    # that still-standing line was published.
    def csv_row(headers, week, row, before = nil)
      return headers.map { |header| before[header] } if unchanged?(before, row)

      values = {
        "week" => week,
        "away_team_slug" => team_slug(row.away_abbr),
        "home_team_slug" => team_slug(row.home_abbr),
        "favorite_team_slug" => team_slug(row.favorite_abbr),
        "favorite_spread" => format("%.1f", row.favorite_spread),
        "game_total" => format("%.1f", row.game_total),
        "source" => source_name,
        "source_published_on" => @today.to_s,
        "source_url" => scoreboard_url(week),
        "source_text" => source_text(row)
      }
      # Any column this source does not fill — the per-side posted_line/odds
      # columns a future POSTED source would — stays blank rather than guessed.
      headers.map { |header| values[header] }
    end

    def unchanged?(before, row)
      return false if before.nil?

      before["favorite_team_slug"] == team_slug(row.favorite_abbr) &&
        before["favorite_spread"].to_f == row.favorite_spread &&
        before["game_total"].to_f == row.game_total
    end

    def source_name
      "draftkings_espn_scoreboard_#{@today.strftime('%Y_%m_%d')}"
    end

    def scoreboard_url(week)
      "#{Nfl::Espn::Client::BASE_URL}/scoreboard?dates=#{@year}&seasontype=#{SEASON_TYPE}&week=#{week}"
    end

    # The human-checkable transcript, in the shape the dataset already carries:
    #   "NYG -7, O/U 45.5 (DraftKings via ESPN scoreboard)"
    def source_text(row)
      spread = format("%g", row.favorite_spread)
      total = format("%g", row.game_total)
      "#{row.favorite_abbr} #{spread}, O/U #{total} (DraftKings via ESPN scoreboard)"
    end
  end
end
