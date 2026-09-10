require "test_helper"
require "tmpdir"

class Nfl::FetchHistoricalScoresTest < ActiveSupport::TestCase
  test "parses completed regular-season games for the requested season" do
    rows = Nfl::FetchHistoricalScores.rows_from(espn_payload, season: 2024)

    assert_equal 1, rows.length
    assert_equal(
      {
        "season" => 2024,
        "week" => 1,
        "away" => "BAL",
        "away_score" => 20,
        "home" => "KC",
        "home_score" => 27
      },
      rows.first
    )
  end

  test "drops postseason, other seasons, and unfinished games" do
    rows = Nfl::FetchHistoricalScores.rows_from(espn_payload, season: 2023)

    assert_equal [], rows
  end

  test "tolerates a payload whose events key is null" do
    assert_equal [], Nfl::FetchHistoricalScores.rows_from({ "events" => nil }, season: 2024)
  end

  # --- the write guard -------------------------------------------------------
  #
  # The invariant: `call` replaces the checked-in dataset only when EVERY
  # requested season contributed at least one completed regular-season game.
  # Anything less must raise, naming the season, with the file left untouched.

  test "writes the dataset when every requested season contributes games" do
    result = fetch_with(2023 => season_payload(2023), 2024 => season_payload(2024))

    written = JSON.parse(@path.read)
    assert_equal 2, result.games
    assert_equal [2023, 2024], written.fetch("seasons")
    assert_equal [2023, 2024], written.fetch("games").map { |g| g.fetch("season") }
  end

  test "refuses to overwrite the dataset when a season returns no events" do
    assert_preserves_dataset(/season 2024/) do
      fetch_with(2023 => season_payload(2023), 2024 => { "events" => [] })
    end
  end

  test "refuses to overwrite the dataset when a season payload has a null events key" do
    assert_preserves_dataset(/season 2023/) do
      fetch_with(2023 => { "events" => nil }, 2024 => season_payload(2024))
    end
  end

  test "refuses to overwrite the dataset when a season payload omits events entirely" do
    assert_preserves_dataset(/season 2023/) do
      fetch_with(2023 => {}, 2024 => season_payload(2024))
    end
  end

  # Events ARE present and the payload is well-formed; every one of them is
  # dropped by the season/type/completed filters. Indistinguishable from an
  # empty payload at the write, and the guard must treat it the same.
  test "refuses to overwrite the dataset when every event is filtered out" do
    all_filtered = {
      "events" => [
        espn_event(year: 2023, type: 3, week: 1, away: ["HOU", "14"], home: ["KC", "23"], completed: true),
        espn_event(year: 2023, type: 2, week: 2, away: ["CIN", "3"], home: ["KC", "7"], completed: false),
        espn_event(year: 2022, type: 2, week: 1, away: ["BAL", "20"], home: ["KC", "27"], completed: true)
      ]
    }

    assert_preserves_dataset(/season 2023/) do
      fetch_with(2023 => all_filtered, 2024 => season_payload(2024))
    end
  end

  test "refuses to write when asked for no seasons at all" do
    assert_preserves_dataset(ArgumentError) do
      Nfl::FetchHistoricalScores.new(seasons: [], path: @path).call
    end
  end

  private

  SENTINEL_DATASET = JSON.pretty_generate("games" => [{ "season" => 2019 }]) + "\n"

  # Seeds a tmp path with a stand-in for the checked-in dataset, so a bad write
  # is observable as replacement rather than creation.
  def setup
    @tmpdir = Dir.mktmpdir
    @path = Pathname(@tmpdir).join("nfl/historical_scores.json")
    @path.dirname.mkpath
    @path.write(SENTINEL_DATASET)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir
  end

  # Asserts the FILE first, so a regression reports the damage that matters
  # ("dataset was overwritten") rather than only the missing exception.
  def assert_preserves_dataset(error = RuntimeError)
    expected, message = error.is_a?(Regexp) ? [RuntimeError, error] : [error, nil]
    raised = begin
      yield
      nil
    rescue expected => e
      e
    end

    assert_equal SENTINEL_DATASET, @path.read, "dataset was overwritten despite an incomplete fetch"
    refute_nil raised, "expected #{expected} naming the offending season"
    assert_match(message, raised.message) if message
  end

  def fetch_with(payloads)
    StubbedFetch.new(payloads: payloads, seasons: payloads.keys, path: @path).call
  end

  # Stands in for the network at the private fetch_season seam, so these tests
  # exercise the real `call` write path.
  class StubbedFetch < Nfl::FetchHistoricalScores
    def initialize(payloads:, **kwargs)
      @payloads = payloads
      super(**kwargs)
    end

    private

    def fetch_season(season)
      @payloads.fetch(season)
    end
  end

  def season_payload(season)
    { "events" => [espn_event(year: season, type: 2, week: 1, away: ["BAL", "20"], home: ["KC", "27"], completed: true)] }
  end

  # Trimmed to the fields the parser reads, in ESPN scoreboard shape: one
  # keeper, one postseason game, one still in progress.
  def espn_payload
    {
      "events" => [
        espn_event(year: 2024, type: 2, week: 1, away: ["BAL", "20"], home: ["KC", "27"], completed: true),
        espn_event(year: 2024, type: 3, week: 1, away: ["HOU", "14"], home: ["KC", "23"], completed: true),
        espn_event(year: 2024, type: 2, week: 2, away: ["CIN", "3"], home: ["KC", "7"], completed: false)
      ]
    }
  end

  def espn_event(year:, type:, week:, away:, home:, completed:)
    {
      "season" => { "year" => year, "type" => type },
      "week" => { "number" => week },
      "competitions" => [
        {
          "status" => { "type" => { "completed" => completed } },
          "competitors" => [
            { "homeAway" => "home", "score" => home[1], "team" => { "abbreviation" => home[0] } },
            { "homeAway" => "away", "score" => away[1], "team" => { "abbreviation" => away[0] } }
          ]
        }
      ]
    }
  end
end
