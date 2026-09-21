require "test_helper"

# [integration] REGRESSION — the admin "Save Multipliers" endpoint used to write
# whatever text the page posted.
#
#   update_all(turf_score: entry[:turf_score].to_f.round(1))
#
# Two defects in that one line, and `update_all` skips validations and callbacks
# by construction, so no model-level validation could have bitten it:
#
#   1. NOTHING BOUNDED THE VALUE. A hand-typed or scripted multiplier landed on
#      the slate whatever it said.
#   2. `.to_f` MISREAD A TYPO IN SILENCE, in two different ways. `"".to_f`,
#      `"—".to_f` and `"x2.5".to_f` are all 0.0; `"2.5x".to_f` is 2.5, truncated
#      rather than zeroed (measured — the ticket had that one backwards). Either
#      way the admin saw "Turf Scores saved!".
#
# The zero half is reachable from the page itself, not only from a fat finger:
# an unranked row renders its multiplier as `—x` (slates/show.html.erb), and
# `saveMultipliers` posts `textContent.replace('x', '')` — so one click on a
# slate with an unpriced team wrote 0.0 onto every game that team plays.
#
# `turf_score` is the column `Selection#compute_points!` settles from, frozen at
# pick time and paid on-chain. A zero there pays a player nothing.
class SlatesTurfScoreBoundsTest < ActionDispatch::IntegrationTest
  setup do
    @slate = Slate.create!(name: "NFL 2026 Week 4", slug: "nfl-2026-week-4")
    log_in_as(users(:alex)) # admin — the pricing board is admin-gated
  end

  def add_game!(team_slug, opponent_slug, expected: 20.0, turf_score: nil, rank: nil)
    game = Game.create!(
      slug: "#{team_slug}-vs-#{opponent_slug}-#{SecureRandom.hex(3)}",
      home_team_slug: team_slug, away_team_slug: opponent_slug, status: "scheduled"
    )
    SlateMatchup.create!(slate: @slate, team_slug: team_slug, opponent_team_slug: opponent_slug,
                         game_slug: game.slug, expected_score: expected, status: "pending",
                         turf_score: turf_score, rank: rank)
  end

  # Two priced teams, so any write this endpoint makes is visible as a change.
  def seed_two_teams!
    @a = add_game!("team-a", "team-b", turf_score: 1.0, rank: 1)
    @b = add_game!("team-b", "team-a", turf_score: 2.0, rank: 2)
  end

  def prices
    SlateMatchup.where(slate: @slate).group(:team_slug).pluck(:team_slug, "MAX(turf_score)")
                .to_h.transform_values(&:to_f)
  end

  def save_multipliers(entries)
    patch update_turf_scores_slate_path(@slate), params: { turf_scores: entries }
  end

  # --- defect 2: a typo must never become 0.0 ------------------------------

  # The values here are the exact three `.to_f` swallowed. Each one is a
  # DIFFERENT way to reach the same zero, and the guard has to refuse all three
  # rather than the one someone remembered.
  {
    "an em dash from an unpriced row" => "—",
    "a multiplier typed with its x" => "2.5x",
    "a multiplier with the x typed first" => "x2.5",
    "an empty cell" => "",
    "whitespace only" => "   ",
    "prose" => "two point five"
  }.each do |label, posted|
    test "#{label} is refused, not silently priced at zero" do
      seed_two_teams!

      save_multipliers([{ id: @b.id, turf_score: posted }])

      assert_redirected_to slate_path(@slate)
      assert_equal({ "team-a" => 1.0, "team-b" => 2.0 }, prices,
                   "a price that could not be read must leave the board untouched")
      assert_match(/not a number/i, flash[:alert])
      assert_match(/Team B/, flash[:alert], "the admin has to be told WHICH row was refused")
      assert_nil flash[:notice], "a refusal must not also report success"
    end
  end

  # --- defect 1: nothing bounded the value ---------------------------------

  test "a multiplier below the curve's pinned floor is refused" do
    seed_two_teams!

    # x0.9 is not a cheap price, it is an impossible one: every price the curve
    # can emit is (1.0 + scale * curve) * game_factor with scale >= 0,
    # curve >= 0 and game_factor >= 1.0, so x1.0 is the structural minimum.
    save_multipliers([{ id: @b.id, turf_score: "0.9" }])

    assert_equal({ "team-a" => 1.0, "team-b" => 2.0 }, prices)
    assert_match(/outside/i, flash[:alert])
    assert_match(/Team B/, flash[:alert])
  end

  test "an explicit zero is refused" do
    seed_two_teams!

    save_multipliers([{ id: @b.id, turf_score: "0" }])

    assert_equal({ "team-a" => 1.0, "team-b" => 2.0 }, prices)
    assert_match(/outside/i, flash[:alert])
  end

  test "a negative multiplier is refused" do
    seed_two_teams!

    save_multipliers([{ id: @b.id, turf_score: "-1.5" }])

    assert_equal({ "team-a" => 1.0, "team-b" => 2.0 }, prices)
    assert_match(/outside/i, flash[:alert])
  end

  test "a multiplier above the widest price this slate's board can show is refused" do
    seed_two_teams!

    # The board's scale slider tops out at 10.0 and this slate has no bye line,
    # so x11.0 is the highest price it can display. x12.0 is a fat finger.
    save_multipliers([{ id: @b.id, turf_score: "12.0" }])

    assert_equal({ "team-a" => 1.0, "team-b" => 2.0 }, prices)
    assert_match(/outside/i, flash[:alert])
  end

  # --- the guard must not fire on correct operator work --------------------

  test "a price above the resolved curve but reachable from the scale slider is saved" do
    seed_two_teams!

    # The NFL curve resolves to scale 1.0, so this slate's own line tops at
    # x2.0. x4.0 is what rank 2 of 2 shows with the slider dragged to 3.0 —
    # a deliberate operator override, and "Save Multipliers" posts exactly what
    # the slider put on screen. A guard that refused this would fire on correct
    # work, and a guard that cries wolf gets turned off.
    save_multipliers([{ id: @b.id, turf_score: "4.0" }])

    assert_redirected_to slate_path(@slate)
    assert_equal({ "team-a" => 1.0, "team-b" => 4.0 }, prices)
    assert_match(/saved/i, flash[:notice])
  end

  test "an ordinary on-curve save still writes every row of a multi-game team" do
    a_first = add_game!("team-a", "team-c", turf_score: 1.0, rank: 1)
    add_game!("team-a", "team-d", turf_score: 1.0, rank: 1)
    b_first = add_game!("team-b", "team-c", turf_score: 2.0, rank: 2)
    add_game!("team-b", "team-d", turf_score: 2.0, rank: 2)

    save_multipliers([{ id: a_first.id, turf_score: "1.0" }, { id: b_first.id, turf_score: "1.8" }])

    assert_match(/saved/i, flash[:notice])
    assert_equal [1.8, 1.8], SlateMatchup.where(slate: @slate, team_slug: "team-b")
                                         .pluck(:turf_score).map(&:to_f),
                 "the edited row is a TEAM: its price applies to every game it plays here"
  end

  # --- the refusal is for the whole batch, not the bad row -----------------

  test "one bad row refuses the whole save rather than half-pricing the slate" do
    seed_two_teams!

    # The board posts every row at once. Writing the readable rows and dropping
    # the rest would leave the slate in a state the admin never typed, under a
    # success flash.
    save_multipliers([
      { id: @a.id, turf_score: "1.3" },
      { id: @b.id, turf_score: "nope" }
    ])

    assert_equal({ "team-a" => 1.0, "team-b" => 2.0 }, prices,
                 "team-a's readable price must NOT land while team-b's is refused")
    assert_match(/No multipliers saved/i, flash[:alert])
  end

  test "the refusal names every offending row, not just the first" do
    seed_two_teams!

    save_multipliers([
      { id: @a.id, turf_score: "0.2" },
      { id: @b.id, turf_score: "2.5x" }
    ])

    assert_match(/Team A/, flash[:alert])
    assert_match(/Team B/, flash[:alert])
  end

  # --- the bye line widens the band, because it widens the board -----------

  test "a bye team may be priced above the full-span ceiling" do
    span = Slate.create!(name: "NFL 2026 Weeks 1-3", slug: "nfl-2026-weeks-1-3")
    %w[team-d team-e team-f].each { |o| add_span_game!(span, "team-a", o) }
    %w[team-e team-f].each { |o| add_span_game!(span, "team-b", o) }
    bye = SlateMatchup.find_by(slate: span, team_slug: "team-b")

    # team-b plays 2 of 3, so it rides the x1.5 line: its ceiling is 1.5x the
    # full-span team's. x16.0 sits under 11.0 * 1.5 and over 11.0.
    patch update_turf_scores_slate_path(span), params: { turf_scores: [{ id: bye.id, turf_score: "16.0" }] }

    assert_match(/saved/i, flash[:notice])
    assert_equal [16.0, 16.0], SlateMatchup.where(slate: span, team_slug: "team-b")
                                           .pluck(:turf_score).map(&:to_f)
  end

  def add_span_game!(slate, team_slug, opponent_slug)
    game = Game.create!(
      slug: "#{team_slug}-vs-#{opponent_slug}-#{SecureRandom.hex(3)}",
      home_team_slug: team_slug, away_team_slug: opponent_slug, status: "scheduled"
    )
    SlateMatchup.create!(slate: slate, team_slug: team_slug, opponent_team_slug: opponent_slug,
                         game_slug: game.slug, expected_score: 20.0, status: "pending")
  end
end
