require "test_helper"

# [unit] THE SITUATION LINES — what the live focus rail says while a game is
# actually being played, and what it refuses to say when it is not.
#
# Composed on the model rather than in the view because TWO surfaces say them:
# the hero tile's rail stacks them over three lines and the scoring banner
# joins two of them onto one. Two copies of the composition is two copies that
# drift, and the operator reads both in the same glance.
class GameSituationTest < ActiveSupport::TestCase
  # NOT a fixture game, for the reason GameScoringTest gives: studio-engine's
  # Sluggable rewrites the slug from #name_slug on every save, so a game built
  # from its own teams stays stable across the updates below.
  setup do
    @home = teams(:team_a)
    @away = teams(:team_b)
    @game = Game.create!(
      home_team_slug: @home.slug, away_team_slug: @away.slug,
      season_year: 2026, season_type: 1, week: 4, status: "in_progress",
      period: 3, clock: "6:06",
      down_distance: "3rd & 9", possession_text: "TMB 13",
      possession_team_slug: @away.slug
    )
  end

  test "a live game composes the three rail lines" do
    assert_equal "Q3 · 6:06", @game.period_clock_label
    assert_equal "3rd & 9", @game.down_distance_label
    assert_equal "TMB on TMB 13", @game.possession_line
  end

  # The banner has ONE row to spend where the rail has three, and down-and-
  # distance and field position are read together — so they are joined rather
  # than given a line each.
  test "the banner's one-line form joins the down to the field position" do
    assert_equal "3rd & 9 at TMB 13", @game.situation_line
  end

  # ── NOT LIVE MEANS NOT SAID ───────────────────────────────────────────────
  #
  # THE GUARD IS ON THE READ, NOT ONLY ON THE WRITE, and it is deliberately
  # belt-and-braces. PollCycle writes the feed's nil through when ESPN drops the
  # situation block, so a finished game's columns SHOULD already be empty — but
  # a game concluded by hand (Game#conclude!, the dev injector, an admin) never
  # goes through that path, and its last snap stays in the columns forever.
  # Reading through the status is what stops a card that says FINAL from also
  # saying "4th & Goal".
  test "a finished game says nothing about the situation, stale columns and all" do
    @game.update!(status: "completed")

    assert_nil @game.period_clock_label
    assert_nil @game.down_distance_label
    assert_nil @game.possession_line
    assert_nil @game.situation_line
    assert_equal "3rd & 9", @game.down_distance, "the column is untouched — only the reading is guarded"
  end

  test "a scheduled game says nothing about the situation" do
    @game.update!(status: "scheduled")

    assert_nil @game.period_clock_label
    assert_nil @game.down_distance_label
    assert_nil @game.possession_line
  end

  # ── OVERTIME IS NOT Q5 ────────────────────────────────────────────────────
  #
  # ESPN counts periods straight past four. A card reading "Q5" is wrong about a
  # thing every viewer can see on their own television.
  test "the fifth period reads as OT" do
    @game.update!(period: 5)

    assert_equal "OT · 6:06", @game.period_clock_label
  end

  test "a period of zero is no period at all" do
    @game.update!(period: 0)

    assert_equal "6:06", @game.period_clock_label, "the clock still stands on its own"
  end

  # ── EACH HALF DEGRADES ON ITS OWN ─────────────────────────────────────────
  #
  # The possession line is built from two different sources — our team record
  # and ESPN's yard-line text — and either can be absent independently. Losing
  # one must not silently cost the other: knowing SEA has the ball is worth
  # saying even when we do not know where, and vice versa.
  test "possession with no yard line still names the team" do
    @game.update!(possession_text: nil)

    assert_equal "TMB", @game.possession_line
  end

  test "a yard line with no possessing team still says where the ball is" do
    @game.update!(possession_team_slug: nil)

    assert_equal "TMB 13", @game.possession_line
  end

  test "neither half means no line" do
    @game.update!(possession_text: nil, possession_team_slug: nil)

    assert_nil @game.possession_line
  end

  # A possession slug naming a team that is not IN this game resolves to no
  # team rather than to a lookup — the two sides are already loaded on any board
  # that renders this, and a third query per tile to confirm a mismatch is a
  # cost paid on every row for an answer that is always "no".
  test "a possession slug from outside the matchup names nobody" do
    @game.update!(possession_team_slug: teams(:team_c).slug)

    assert_nil @game.possession_team
    assert_equal "TMB 13", @game.possession_line
  end

  # A live game between snaps carries a clock and nothing else. The rail falls
  # back to ESPN's own detail there ("Halftime"), which is a VIEW decision — the
  # model's job is to report honestly that it has no down to give.
  test "a live game with no situation yet reports only the clock" do
    @game.update!(down_distance: nil, possession_text: nil, possession_team_slug: nil)

    assert_equal "Q3 · 6:06", @game.period_clock_label
    assert_nil @game.down_distance_label
    assert_nil @game.possession_line
    assert_nil @game.situation_line
  end
end
