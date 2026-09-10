require "test_helper"

# [integration] The scorer, from ESPN's play text through to a headshot.
#
# The extractor has its own unit test; this covers the seam BELOW it — resolving
# a parsed name to a roster athlete, and the rule that decides whether a score
# earns the focus panel's reveal.
class GoalScorerTest < ActiveSupport::TestCase
  setup do
    @team = teams(:team_a)
    teams(:team_b).update!(league: "nfl", sport: "football")

    # BUILT, NOT TAKEN FROM THE FIXTURES. Game includes Sluggable, which
    # re-stamps the slug on every save from the two team slugs — and the fixture
    # games carry hand-written slugs ("past-game") that do not match what it
    # would stamp. Creating one goal is enough to trigger it: Goal's after_create
    # saves the game to recompute its score, Sluggable renames it, and the goal's
    # game_slug is left pointing at a slug nothing has any more. Creating the
    # game here means its slug is already what Sluggable wants.
    @game = Game.create!(
      home_team_slug: @team.slug, away_team_slug: teams(:team_b).slug,
      season_year: 2026, season_type: 1, week: 4, status: "in_progress"
    )
  end

  def goal(**attrs)
    @game.goals.create!({ team_slug: @team.slug, points: 6, scoring_type: "touchdown" }.merge(attrs))
  end

  # ── RESOLUTION ────────────────────────────────────────────────────────────

  test "a name matching a roster athlete resolves to their slug" do
    assert_equal "pat-passer", Goal.resolve_scorer_slug("Pat Passer")
  end

  test "an unknown name resolves to nothing rather than raising" do
    assert_nil Goal.resolve_scorer_slug("Nobody Here")
    assert_nil Goal.resolve_scorer_slug(nil)
    assert_nil Goal.resolve_scorer_slug("")
  end

  # A single token is a team, not a person — and Person.find_by_name needs both
  # halves of a name to do anything sensible with it.
  test "a one-word name resolves to nothing" do
    assert_nil Goal.resolve_scorer_slug("Passer")
  end

  # A PERSON WITHOUT AN ATHLETE PROFILE IS NOT A SCORER. The people table also
  # carries coaches; resolving to one would hand the card a person with no
  # headshot and no position.
  test "a person with no athlete profile does not resolve" do
    Person.create!(first_name: "Coach", last_name: "Only")
    assert_nil Goal.resolve_scorer_slug("Coach Only")
  end

  # ESPN writes the suffix, nflverse often does not. Measured across 141 real
  # scorers this retry is worth three percentage points of resolution.
  test "a suffix ESPN adds does not lose the match" do
    assert_equal "pat-passer", Goal.resolve_scorer_slug("Pat Passer Jr.")
    assert_equal "pat-passer", Goal.resolve_scorer_slug("Pat Passer III")
  end

  test "the suffix retry never invents a match" do
    assert_nil Goal.resolve_scorer_slug("Nobody Here Jr.")
  end

  # ── THE ATHLETE AND THE HEADSHOT ──────────────────────────────────────────

  test "a resolved goal reaches its athlete and their headshot" do
    g = goal(scorer_name: "Pat Passer", scorer_slug: "pat-passer")

    assert_equal athletes(:passer), g.scorer_athlete
    assert_includes g.scorer_headshot_url(width: 400), "/400.png"
    assert_includes g.scorer_headshot_url(width: 100), "/100.png"
  end

  test "an unresolved goal has no athlete and no headshot, and does not raise" do
    g = goal(scorer_name: "Practice Squad", scorer_slug: nil)

    assert_nil g.scorer_athlete
    assert_nil g.scorer_headshot_url
  end

  # The fallback path the card renders as initials: we know WHO scored, we just
  # hold no picture of them. `rusher` has an athlete row but no cached image.
  test "a resolved scorer with no cached image still names the athlete" do
    g = goal(scorer_name: "Rhea Rusher", scorer_slug: "rhea-rusher")

    assert_equal athletes(:rusher), g.scorer_athlete
    assert_nil g.scorer_headshot_url, "no cached variant means no URL, and the card shows initials"
  end

  # ── WHICH SCORES TAKE OVER THE PANEL ──────────────────────────────────────

  test "touchdowns and field goals reveal" do
    assert goal(scoring_type: "touchdown", scorer_name: "Pat Passer").reveals_scorer?
    assert goal(scoring_type: "field_goal", points: 3, scorer_name: "Pat Passer").reveals_scorer?
  end

  # The extra point and the two-point try are the SAME PLAY as the touchdown as
  # far as the feed is concerned — revealing them would interrupt twice for one
  # drive. A safety rarely names one clean scorer.
  test "extra points, conversions and safeties do not reveal" do
    %w[pat two_point safety goal].each do |type|
      refute goal(scoring_type: type, points: 1, scorer_name: "Pat Passer").reveals_scorer?,
        "#{type} should not take over the panel"
    end
  end

  test "a score with no scorer never reveals, whatever its type" do
    refute goal(scoring_type: "touchdown", scorer_name: nil).reveals_scorer?
    refute goal(scoring_type: "field_goal", points: 3, scorer_name: "").reveals_scorer?
  end

  # An unresolved scorer STILL reveals: the card names them and draws their
  # initials. Gating the reveal on the headshot would silently drop roughly one
  # scorer in ten.
  test "a scorer with no athlete record still reveals" do
    g = goal(scoring_type: "touchdown", scorer_name: "Practice Squad", scorer_slug: nil)

    assert g.reveals_scorer?
    assert_nil g.scorer_headshot_url
  end
end
