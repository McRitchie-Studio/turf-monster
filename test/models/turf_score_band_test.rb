require "test_helper"

# [unit] The two rules the admin write path is built on: how a posted price is
# READ, and which prices this slate will ACCEPT.
#
# Both live on the model rather than in the controller because the controller
# writes with `update_all`, which skips validations and callbacks — the check
# has to be callable at the write, and a rule that is callable is a rule that
# can be tested at this tier.
class TurfScoreBandTest < ActiveSupport::TestCase
  include SlatesHelper

  # --- reading a posted price ----------------------------------------------

  # Each row is a value `.to_f` used to misread, with no complaint, on a column
  # that settles picks — some to 0.0 and some to a truncated price. `Float()`
  # raises instead, which is the whole point: "the admin typed 0" and "the admin
  # typed something unreadable" are opposite statements and `.to_f` collapses
  # them into one.
  {
    "2.5x" => nil,          # the multiplier typed with its suffix (.to_f TRUNCATES this to 2.5)
    "x2.5" => nil,          # the x typed first (.to_f ZEROES this)
    "—" => nil,             # what an UNPRICED row's display renders — reachable from the page
    "" => nil,
    "   " => nil,
    "two point five" => nil,
    "1.2.3" => nil,
    "NaN" => nil,
    "1e400" => nil,         # Float() returns Infinity here rather than raising
    nil => nil,
    "1.4" => 1.4,
    " 1.4 " => 1.4,         # the board pads nothing, but a paste does
    "1.44" => 1.4,          # stored to a tenth, the way the board shows it
    "1.45" => 1.5,
    "2" => 2.0,
    "0" => 0.0,             # READABLE, and refused later by the band — not here
    "-1.5" => -1.5,
    1.4 => 1.4              # already a number
  }.each do |raw, expected|
    test "parse_turf_score(#{raw.inspect}) is #{expected.inspect}" do
      assert_equal expected, SlateMatchup.parse_turf_score(raw)
    end
  end

  # The old behaviour, pinned so the two failure modes stay distinguishable. The
  # ticket said `"2.5x"` became 0.0; measured, it becomes 2.5. Both are wrong,
  # but only one of them pays a player nothing, and a guard written against the
  # remembered version would have missed the leading-x spelling entirely.
  test "to_f misreads in two ways, and parse_turf_score refuses both" do
    assert_equal 0.0, "".to_f
    assert_equal 0.0, "—".to_f
    assert_equal 0.0, "x2.5".to_f
    assert_equal 2.5, "2.5x".to_f, "TRUNCATED, not zeroed — the ticket had this backwards"

    ["", "—", "x2.5", "2.5x"].each { |raw| assert_nil SlateMatchup.parse_turf_score(raw), raw.inspect }
    assert_equal 0.0, SlateMatchup.parse_turf_score("0"), "a typed zero IS a number; the band refuses it"
  end

  # --- the band ------------------------------------------------------------

  test "the floor is x1.0 on every slate, because the curve cannot emit less" do
    [
      { teams: 32, sport: "nfl", game_factors: [1.0] },
      { teams: 32, sport: "nfl", game_factors: [1.0, 1.5] },
      { teams: 8, sport: "fifa", game_factors: [1.0] },
      { teams: 2, sport: "fifa", game_factors: [1.0, 3.0] }
    ].each do |args|
      assert_equal 1.0, SlateMatchup.price_band(**args).first, args.inspect
    end
  end

  test "the ceiling is the top slider scale on the widest line the slate has" do
    # 1.0 + 10.0 * 1.0 = x11.0 for a full-span team...
    assert_equal 11.0, SlateMatchup.price_band(teams: 32, sport: "nfl").last
    # ...and 1.5x that for a team playing 2 of a 3-game span.
    assert_equal 16.5, SlateMatchup.price_band(teams: 32, sport: "nfl", game_factors: [1.0, 1.5]).last
    assert_equal 33.0, SlateMatchup.price_band(teams: 32, sport: "nfl", game_factors: [1.0, 3.0]).last
  end

  # An empty or one-team slate can only ever price x1.0 — the curve has no rank
  # to climb — so the band collapses to that rather than raising on the divide
  # by (n - 1). Nothing can be posted against an empty slate anyway; this is
  # here so the guard cannot be the thing that 500s the page.
  test "the band degrades rather than raising on a slate with nothing in it" do
    assert_equal 1.0..1.0, SlateMatchup.price_band(teams: 0, sport: "nfl", game_factors: [])
    assert_equal 1.0..1.0, SlateMatchup.price_band(teams: 1, sport: "nfl")
    assert_equal 1.0..1.5, SlateMatchup.price_band(teams: 1, sport: "nfl", game_factors: [1.0, 1.5])
  end

  # THE PROPERTY THAT MATTERS: the guard cannot refuse the board's own output.
  #
  # "Save Multipliers" posts whatever the price table put on screen, so any
  # price that table can hold MUST be acceptable. If this ever fails, the guard
  # has drifted from the page and will start firing on correct operator work —
  # which is how a guard gets deleted, and then the typo is unguarded too.
  [
    { name: "NFL 2026 Week 4", teams: 32, factors: [1.0] },
    { name: "NFL 2026 Weeks 1-3", teams: 32, factors: [1.0, 1.5] },
    { name: "World Cup 2026 Group 1", teams: 4, factors: [1.0] },
    { name: "World Cup 2026 Round of 32", teams: 2, factors: [1.0, 2.0] }
  ].each do |slate_spec|
    test "every price the board can show on #{slate_spec[:name]} is inside the band" do
      slate = Slate.new(name: slate_spec[:name])
      band = SlateMatchup.price_band(teams: slate_spec[:teams], sport: slate.sport,
                                     game_factors: slate_spec[:factors])

      table = turf_score_scale_table(slate: slate, teams: slate_spec[:teams],
                                     factors: slate_spec[:factors],
                                     resolved_scale: slate.resolved_formula[:formula_mult_scale])
      prices = table.values.flat_map { |by_line| by_line.values.flatten }

      assert_operator prices.size, :>, 0
      outside = prices.reject { |price| band.cover?(price) }.uniq.sort
      assert_empty outside,
                   "the board can display #{outside.inspect} but the server would refuse it — " \
                   "band #{band.inspect}"
    end
  end

  test "the slider grid has ONE definition, so the table and the band cannot drift" do
    assert_same SlateMatchup::SLIDER_SCALES, SlatesHelper::SLIDER_SCALES
    assert_equal 0.0, SlateMatchup::SLIDER_SCALES.min
    assert_equal 10.0, SlateMatchup::SLIDER_SCALES.max,
                 "the view's range input is min=0 max=10 step=0.5; change both together"
  end

  # --- the slate's own band ------------------------------------------------

  test "a slate with a bye in the span carries the wider ceiling its bye line earns" do
    slate = Slate.create!(name: "NFL 2026 Weeks 1-3", slug: "band-span-#{SecureRandom.hex(3)}")
    %w[team-c team-d team-e].each { |o| add_game!(slate, "team-a", o) }
    %w[team-d team-e].each { |o| add_game!(slate, "team-b", o) }

    assert_equal 1.5, slate.game_factors["team-b"], "team-b plays 2 of 3"
    assert_equal 1.0..16.5, slate.admin_price_band
  end

  test "a one-week slate gets the full-span ceiling and nothing wider" do
    slate = Slate.create!(name: "NFL 2026 Week 4", slug: "band-week-#{SecureRandom.hex(3)}")
    add_game!(slate, "team-a", "team-b")
    add_game!(slate, "team-b", "team-a")

    assert_equal 1.0..11.0, slate.admin_price_band
  end

  # --- defense in depth on the validated writers ---------------------------

  test "a below-floor price is refused by the model for every update! writer" do
    slate = Slate.create!(name: "NFL 2026 Week 4", slug: "band-val-#{SecureRandom.hex(3)}")
    matchup = add_game!(slate, "team-a", "team-b")

    assert_not matchup.update(turf_score: 0.0)
    assert_match(/greater than or equal to 1/, matchup.errors.full_messages.join)
    assert matchup.update(turf_score: 1.0)
    assert matchup.update(turf_score: nil), "an unpriced row is legal; a zero-priced one is not"
  end

  def add_game!(slate, team_slug, opponent_slug)
    game = Game.create!(
      slug: "#{team_slug}-vs-#{opponent_slug}-#{SecureRandom.hex(3)}",
      home_team_slug: team_slug, away_team_slug: opponent_slug, status: "scheduled"
    )
    SlateMatchup.create!(slate: slate, team_slug: team_slug, opponent_team_slug: opponent_slug,
                         game_slug: game.slug, expected_score: 20.0, status: "pending")
  end
end
