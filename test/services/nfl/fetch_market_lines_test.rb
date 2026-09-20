require "test_helper"
require "csv"

# [integration] The DraftKings pull, from ESPN payload to the seed dataset on
# disk. The payload is the REAL captured fixture the parse seam uses; what is
# exercised here is everything around it — the refusals, and the write.
class Nfl::FetchMarketLinesTest < ActiveSupport::TestCase
  ABBREVIATIONS = { "DAL" => "dallas-cowboys", "TB" => "tampa-bay-buccaneers",
                    "PHI" => "philadelphia-eagles", "JAX" => "jacksonville-jaguars",
                    "CHI" => "chicago-bears", "GB" => "green-bay-packers" }.freeze

  # The dataset's real header, in its real order.
  HEADERS = %w[week away_team_slug home_team_slug favorite_team_slug favorite_spread game_total
               source source_published_on source_url source_text].freeze

  setup do
    ABBREVIATIONS.each do |abbreviation, slug|
      Team.find_or_create_by!(slug: slug) do |team|
        team.name = slug.titleize
        team.short_name = abbreviation
        team.league = "nfl"
        team.sport = "football"
      end
    end

    @path = Rails.root.join("tmp", "market_lines_test_#{SecureRandom.hex(4)}.csv")
    write_csv([
      # TB at DAL carries the SAME line the fixture does — the unmoved row.
      ["5", "tampa-bay-buccaneers", "dallas-cowboys", "dallas-cowboys", "-3.5", "52.5",
       "yahoo_lookahead", "2026-05-26", "https://example.test/lookahead", "old transcript"],
      # PHI at JAX has moved since it was written.
      ["5", "philadelphia-eagles", "jacksonville-jaguars", "jacksonville-jaguars", "-2.5", "44.5",
       "yahoo_lookahead", "2026-05-26", "https://example.test/lookahead", "old transcript"],
      ["5", "chicago-bears", "green-bay-packers", "green-bay-packers", "-3.0", "49.5",
       "yahoo_lookahead", "2026-05-26", "https://example.test/lookahead", "old transcript"],
      # A different week, which this run must not touch.
      ["9", "chicago-bears", "dallas-cowboys", "dallas-cowboys", "-1.0", "40.0",
       "yahoo_lookahead", "2026-05-26", "https://example.test/lookahead", "week nine"]
    ])
  end

  teardown { File.delete(@path) if File.exist?(@path) }

  def write_csv(rows)
    CSV.open(@path, "w") do |csv|
      csv << HEADERS
      rows.each { |row| csv << row }
    end
  end

  def table
    CSV.read(@path, headers: true)
  end

  def payload
    @payload ||= JSON.parse(file_fixture("espn_scoreboard_odds_week5.json").read)
  end

  # A client that answers with the captured payload, and records what it was asked.
  def client_for(payload_by_week)
    Class.new do
      attr_reader :asked

      def initialize(payloads)
        @payloads = payloads
        @asked = []
      end

      def scoreboard(year:, season_type:, week:)
        @asked << [year, season_type, week]
        @payloads.fetch(week)
      end
    end.new(payload_by_week)
  end

  def call(apply: false, allow_schedule_change: false, payloads: { 5 => payload })
    Nfl::FetchMarketLines.call(year: 2026, weeks: payloads.keys, path: @path, apply: apply,
                               allow_schedule_change: allow_schedule_change,
                               client: client_for(payloads), today: Date.new(2026, 9, 19))
  end

  test "a dry run reports the line moves and writes nothing" do
    before = File.read(@path)

    result = call

    assert_nil result.refusal
    assert_not result.applied
    assert_equal before, File.read(@path), "a dry run must not touch the dataset"
    moved = result.changes.map { |change| [change.away_team_slug, change.field, change.old, change.new] }
    assert_includes moved, ["philadelphia-eagles", "spread", -2.5, -1.5]
    assert_includes moved, ["philadelphia-eagles", "total", 44.5, 45.5]
    assert_includes moved, ["philadelphia-eagles", "favorite", "jacksonville-jaguars", "philadelphia-eagles"]
    assert_equal 3, result.rows
  end

  test "apply rewrites only the rows whose line actually moved" do
    result = call(apply: true)

    assert result.applied
    rows = table.index_by { |row| row["away_team_slug"] }

    moved = rows.fetch("philadelphia-eagles")
    assert_equal ["philadelphia-eagles", "-1.5", "45.5"],
                 moved.values_at("favorite_team_slug", "favorite_spread", "game_total")
    assert_equal "draftkings_espn_scoreboard_2026_09_19", moved["source"]
    assert_equal "2026-09-19", moved["source_published_on"]
    assert_equal "PHI -1.5, O/U 45.5 (DraftKings via ESPN scoreboard)", moved["source_text"]

    # The unmoved row keeps its ORIGINAL stamp: re-dating every row on each pull
    # would bury the one game that moved under a 45-row diff.
    unmoved = rows.fetch("tampa-bay-buccaneers")
    assert_equal "yahoo_lookahead", unmoved["source"]
    assert_equal "2026-05-26", unmoved["source_published_on"]
  end

  test "a week the run did not ask for is left alone" do
    call(apply: true)

    week_nine = table.find { |row| row["week"] == "9" }
    assert_equal "week nine", week_nine["source_text"]
    assert_equal 4, table.size, "no row is added or dropped"
  end

  test "a game with no DraftKings line refuses the whole run" do
    no_dk = JSON.parse(payload.to_json)
    no_dk["events"].first["competitions"].first["odds"] = []
    before = File.read(@path)

    result = call(apply: true, payloads: { 5 => no_dk })

    assert_match(/no readable DraftKings line/, result.refusal)
    assert_not result.applied
    assert_equal before, File.read(@path), "a refusal writes NOTHING, not the readable rows"
  end

  test "a team the app does not know refuses rather than writing a blank slug" do
    Team.find_by(short_name: "JAX").update!(league: "xfl")
    before = File.read(@path)

    result = call(apply: true)

    assert_match(/unknown team JAX/, result.refusal)
    assert_equal before, File.read(@path)
  end

  test "schedule drift refuses, and says which game moved" do
    write_csv([["5", "tampa-bay-buccaneers", "dallas-cowboys", "dallas-cowboys", "-3.5", "52.5",
                "yahoo_lookahead", "2026-05-26", "https://example.test/lookahead", "old transcript"]])

    result = call(apply: true)

    assert_match(/schedule moved/, result.refusal)
    assert_match(/adds philadelphia-eagles at jacksonville-jaguars/, result.refusal)
    assert_equal 1, table.size, "the dataset is untouched while the operator decides"
  end

  test "drift can be accepted deliberately, and then it writes" do
    write_csv([["5", "tampa-bay-buccaneers", "dallas-cowboys", "dallas-cowboys", "-3.5", "52.5",
                "yahoo_lookahead", "2026-05-26", "https://example.test/lookahead", "old transcript"]])

    result = call(apply: true, allow_schedule_change: true)

    assert_nil result.refusal
    assert result.applied
    assert_equal 3, table.size, "the week is rewritten whole"
  end

  test "it asks ESPN for the regular season, week by week" do
    fetcher = client_for({ 5 => payload })
    Nfl::FetchMarketLines.call(year: 2026, weeks: [5], path: @path, client: fetcher,
                               today: Date.new(2026, 9, 19))

    assert_equal [[2026, 2, 5]], fetcher.asked
  end
end
