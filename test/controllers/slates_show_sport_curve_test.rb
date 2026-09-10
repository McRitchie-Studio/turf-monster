require "test_helper"

# The slate show page compartmentalizes the Turf Score curve by sport: NFL
# slates render/save the linear curve, soccer slates the log curve, and the
# base is pinned — no Base slider, rank 1 always x1.0.
class SlatesShowSportCurveTest < ActionDispatch::IntegrationTest
  setup do
    log_in_as(users(:alex)) # admin — the ranking UI is admin-gated
    @nfl = Slate.create!(name: "NFL 2026 Week 9 Test", slug: "nfl-2026-week-9-test")
    @fifa = Slate.create!(name: "Semi-finals Test", slug: "semi-finals-test")
  end

  test "nfl slate page carries the linear curve and pinned base" do
    get slate_path(@nfl)

    assert_response :success
    assert_includes response.body, "FC_SPORT = 'nfl'"
    assert_includes response.body, "(rank − 1) / (N − 1)"
    assert_includes response.body, "pinned — rank 1 is always x1.0"
    refute_includes response.body, 'x-model.number="multBase"'
    # Goals are a soccer concept: no goals sliders on an NFL slate, and the
    # resolved scale defaults to the x2.0 NFL top.
    refute_includes response.body, 'x-model.number="goalBase"'
    assert_equal 1.0, @nfl.resolved_formula[:formula_mult_scale]
  end

  test "soccer slate page keeps the log curve and goals card" do
    get slate_path(@fifa)

    assert_response :success
    assert_includes response.body, "FC_SPORT = 'fifa'"
    assert_includes response.body, "ln(rank) / ln(N)"
    refute_includes response.body, 'x-model.number="multBase"'
    assert_includes response.body, 'x-model.number="goalBase"'
    assert_equal 2.0, @fifa.resolved_formula[:formula_mult_scale]
  end

  test "saving nfl rankings writes the linear pinned-base scores" do
    matchups = %w[team-a team-b team-c].map do |slug|
      SlateMatchup.create!(slate: @nfl, team_slug: slug, status: "pending")
    end

    patch update_rankings_slate_path(@nfl), params: { matchup_ids: matchups.map(&:id) }

    assert_redirected_to slate_path(@nfl)
    assert_equal [1.0, 1.5, 2.0], matchups.map { |m| m.reload.turf_score.to_f }
    assert_equal [1, 2, 3], matchups.map { |m| m.rank }
  end
end
