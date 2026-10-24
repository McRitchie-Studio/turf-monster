# frozen_string_literal: true

require "test_helper"
require "tempfile"

# [integration] THE LIVE-SCORE READER, BY WEEK.
#
# Nfl::LiveScores::CurrentSlot picks the week /live shows and `games_for` loads
# it through Game.in_season_slot — the same scope the poller's focus ladder and
# Nfl::LiveBroadcast use. Before games-week-backfill, the odds-CSV writer set no
# week, so a week it created was invisible to this reader until the poller
# happened to reach it; and a half-stamped row (year, no week) handed the slot
# scope `week: nil`, which matched every unstamped game of the season at once.
class LiveScoreWeekReaderTest < ActiveSupport::TestCase
  setup do
    %i[team_b team_c team_d].each { |key| teams(key).update!(league: "nfl", sport: "football") }
  end

  test "a week the odds CSV wrote is the live week, and its games are the board" do
    Nfl::CacheExpectedTeamTotals.call(path: csv_path(week: 8))

    slot = Nfl::LiveScores::CurrentSlot.call

    assert_equal({ year: 2026, season_type: 2, week: 8 }, slot)
    assert_equal ["team-a-vs-team-b"], Nfl::LiveScores::CurrentSlot.games_for(slot).map(&:slug)
  end

  test "a backfilled legacy week becomes reachable by its slot" do
    slate = Slate.create!(name: "NFL 2026 Week 8", slug: "nfl-2026-week-8", year: 2026, week: 8)
    legacy = Game.new(slug: "team-a-vs-team-b", home_team_slug: "team-a", away_team_slug: "team-b",
                      kickoff_at: 2.days.from_now)
    legacy.save!(validate: false)
    SlateMatchup.create!(slate: slate, team_slug: "team-a", opponent_team_slug: "team-b", game_slug: legacy.slug, week: 8)
    slot = { year: 2026, season_type: 2, week: 8 }
    assert_empty Nfl::LiveScores::CurrentSlot.games_for(slot), "the defect: week 8 reads as empty"

    Games::BackfillWeek.call(apply: true)

    assert_equal [legacy.slug], Nfl::LiveScores::CurrentSlot.games_for(slot).map(&:slug)
    assert_equal slot, Nfl::LiveScores::CurrentSlot.call
  end

  # The nil-safety fix: a half-stamped row can neither become the live week nor
  # make the board a heap of every unstamped game.
  test "a half-stamped game never becomes the live week" do
    stamped = Game.create!(slug: "team-c-vs-team-d", home_team_slug: "team-c", away_team_slug: "team-d",
                           season_year: 2026, season_type: 2, week: 7, kickoff_at: 3.days.from_now)
    half = Game.new(slug: "team-a-vs-team-b", home_team_slug: "team-a", away_team_slug: "team-b",
                    season_year: 2026, season_type: 2, kickoff_at: 1.day.from_now)
    half.save!(validate: false)

    slot = Nfl::LiveScores::CurrentSlot.call

    assert_equal({ year: 2026, season_type: 2, week: 7 }, slot)
    assert_equal [stamped.slug], Nfl::LiveScores::CurrentSlot.games_for(slot).map(&:slug)
    assert_empty Nfl::LiveScores::CurrentSlot.games_for({ year: 2026, season_type: 2, week: nil })
  end

  private

  def csv_path(week:)
    file = Tempfile.new(["team_totals", ".csv"])
    file.write <<~CSV
      week,away_team_slug,home_team_slug,favorite_team_slug,favorite_spread,game_total,source,source_published_on,source_url,source_text
      #{week},team-b,team-a,team-a,-3,47,test_source,2026-05-26,https://example.test/team-totals,Lookahead
    CSV
    file.close
    file.path
  end
end
