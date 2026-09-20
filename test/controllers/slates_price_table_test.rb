require "test_helper"

# [component] The admin board reads prices; it does not compute them.
class SlatesPriceTableTest < ActionDispatch::IntegrationTest
  setup do
    log_in_as(users(:alex)) # admin — the ranking UI is admin-gated
    @slate = Slate.create!(name: "NFL 2026 Week 9 Test", slug: "nfl-2026-week-9-test", week: 9)
    %w[team-a team-b team-c].each_with_index do |slug, index|
      game = Game.create!(slug: "#{slug}-vs-team-d", home_team_slug: slug, away_team_slug: "team-d",
                          status: "scheduled")
      SlateMatchup.create!(slate: @slate, team_slug: slug, opponent_team_slug: "team-d",
                           game_slug: game.slug, expected_score: 20.0 - index, week: 9, status: "pending",
                           rank: index + 1,
                           turf_score: SlateMatchup.turf_score_for(index + 1, 3, sport: "nfl"))
    end
  end

  test "the page carries Ruby's price for every slider position" do
    get slate_path(@slate)

    assert_response :success
    table = JSON.parse(response.body[/var _fcPrices = (\{.*?\});/m, 1])
    assert_equal 21, table.size, "one entry per slider position"
    table.each do |scale, lines|
      lines.fetch("1.0").each_with_index do |price, index|
        assert_equal SlateMatchup.turf_score_for(index + 1, 3, sport: "nfl", scale: scale.to_f), price
      end
    end
  end

  # THE REGRESSION THIS PAGE ALMOST SHIPPED. `multScale` is seeded from the
  # slate's resolved formula, not from the slider, and the Admin Formula field
  # that writes it steps by 0.1 — so a scale of 2.3 is one admin keystroke away
  # and matches no slider position. Before the fix the lookup missed, every row
  # priced null, and a drag-reorder plus "Save Multipliers" wrote each team's
  # old price against its new rank. `Selection#compute_points!` settles from
  # that column, so the board paid the wrong multiplier.
  test "an off-grid resolved scale prices every row" do
    @slate.update!(formula_mult_scale: 2.3)

    get slate_path(@slate)

    assert_response :success
    seeded = response.body[/multScale: ([0-9.]+),/, 1]
    assert_equal "2.3", seeded, "the page must seed a scale the table has a key for"

    table = JSON.parse(response.body[/var _fcPrices = (\{.*?\});/m, 1])
    prices = table.fetch(seeded, {}).fetch("1.0", [])
    assert_equal 3, prices.size, "the seeded scale must have a row, or every price reads null"
    assert prices.none?(&:nil?), "a null price is what the save path persists against the wrong rank"
    prices.each_with_index do |price, index|
      assert_equal SlateMatchup.turf_score_for(index + 1, 3, sport: "nfl", scale: 2.3), price
    end
  end

  # The defect was a SECOND implementation, so the regression guard is that the
  # arithmetic did not come back — not that one value is right.
  test "no curve arithmetic survives in the page's JavaScript" do
    get slate_path(@slate)

    assert_no_match(/1\.0 \+ multScale \* curve/, response.body,
                    "the JS curve is what diverged from Ruby on a tie; it must stay deleted")
    assert_match(/_fcPrices\[\(multScale \|\| 0\)\.toFixed\(1\)\]/, response.body,
                 "the page must LOOK UP a price")
  end
end
