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

  # THE BANNER PRINTS THE TWO AT DIFFERENT WEIGHTS, so they stay two values.
  # "3rd & 9" is the fact; "at TMB 13" is where it is happening, and a
  # nine-character location at the same size competed with the score beside it.
  # The preposition rides the spot because it belongs to it grammatically and
  # never appears without it.
  test "the field spot is its own phrase, preposition included" do
    assert_equal "at TMB 13", @game.field_spot_label
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
    assert_nil @game.field_spot_label
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
    assert_nil @game.field_spot_label
  end

  # A live game with a yard line but no down still says where the ball is — the
  # spot does not depend on the down, and the banner prints whichever it has.
  test "the field spot stands without a down" do
    @game.update!(down_distance: nil)

    assert_nil @game.down_distance_label
    assert_equal "at TMB 13", @game.field_spot_label
  end

  # ── where the ball is, for the drawn field ───────────────────────────────
  #
  # 0..100 from the AWAY goal line: the field is drawn away-left, home-right.

  def field_game(**attributes)
    Game.new(home_team: teams(:team_a), away_team: teams(:team_b), **attributes)
  end

  test "reads the ball's yard line from the feed's own label" do
    assert_equal 13, field_game(possession_text: "TMB 13").ball_yard_line, "on the away side: yards from its goal line"
    assert_equal 87, field_game(possession_text: "TMA 13").ball_yard_line, "on the home side: counted back from the far end"
    assert_equal 50, field_game(possession_text: "50").ball_yard_line
  end

  test "draws no ball it cannot place" do
    assert_nil field_game(possession_text: nil).ball_yard_line
    assert_nil field_game(possession_text: "XYZ 20").ball_yard_line, "a team that is not in this game"
    assert_nil field_game(possession_text: "somewhere").ball_yard_line
  end

  test "the chains are ahead of the offence, whichever way it is going" do
    away_ball = field_game(possession_text: "TMB 13", down_distance: "3rd & 9", possession_team_slug: "team-b")
    home_ball = field_game(possession_text: "TMB 13", down_distance: "3rd & 9", possession_team_slug: "team-a")

    assert_equal 22, away_ball.line_to_gain_yard_line, "the away side attacks toward 100"
    assert_equal 4,  home_ball.line_to_gain_yard_line, "the home side attacks toward 0"
  end

  test "goal to go puts the chains on the goal line" do
    assert_equal 100, field_game(possession_text: "TMA 3", down_distance: "1st & Goal at TMA 3",
                                 possession_team_slug: "team-b").line_to_gain_yard_line
    assert_equal 0, field_game(possession_text: "TMB 3", down_distance: "1st & Goal",
                               possession_team_slug: "team-a").line_to_gain_yard_line
  end

  test "no chains without a ball, a possession or a distance" do
    assert_nil field_game(possession_text: "TMB 13", down_distance: "3rd & 9").line_to_gain_yard_line
    assert_nil field_game(possession_text: nil, down_distance: "3rd & 9", possession_team_slug: "team-b").line_to_gain_yard_line
    assert_nil field_game(possession_text: "TMB 13", down_distance: nil, possession_team_slug: "team-b").line_to_gain_yard_line
  end

  # The feed's down text carries the yard line; the banner prints the yard
  # line again as its own phrase, so it must take the down alone.
  test "the down label is the down without its spot" do
    live = ->(down) { Game.new(status: "in_progress", down_distance: down) }

    assert_equal "3rd & 10", live.("3rd & 10 at ARI 34").down_label
    assert_equal "1st & Goal", live.("1st & Goal at CAR 3").down_label
    assert_equal "3rd & 9", live.("3rd & 9").down_label
    assert_nil live.(nil).down_label
    assert_nil Game.new(status: "scheduled", down_distance: "3rd & 9 at ARI 3").down_label
  end

  # ── the venue, in its two halves ─────────────────────────────────────────

  test "splits a venue into the building and the place at the first comma" do
    game = Game.new(venue: "Tottenham Hotspur Stadium, London, England")

    assert_equal "Tottenham Hotspur Stadium", game.venue_stadium
    assert_equal "London, England", game.venue_location
  end

  test "a venue with no comma is all building; a blank one is neither" do
    assert_equal "Neutral Site", Game.new(venue: "Neutral Site").venue_stadium
    assert_nil Game.new(venue: "Neutral Site").venue_location
    assert_nil Game.new(venue: " ").venue_stadium
    assert_nil Game.new(venue: nil).venue_location
  end
end
