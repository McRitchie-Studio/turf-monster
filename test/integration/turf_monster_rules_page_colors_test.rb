require "test_helper"

# [integration] /turf-monster-v1 → Team rows → the rendered card's CSS.
#
# THE REGRESSION THIS EXISTS FOR. The example cards were first drawn in flat
# surface-alt grey, and the operator's note was "you're missing the team
# coloring — check the new card". The fix routes them through the SAME helper the
# real board uses (TeamColorsHelper#team_card_palette) off the SAME Team rows, so
# re-tuning a team's brand re-colors this page in the same commit.
#
# That property is invisible to a controller test: the fixtures carry no NFL
# teams, so every card renders in the nil-safe neutral fallback and a page that
# had silently gone back to grey would still be green. This test supplies real
# rows and asserts their colors reach the HTML.
class TurfMonsterRulesPageColorsTest < ActionDispatch::IntegrationTest
  # Brand hex as the app stores it. Deliberately NOT read from the DB or from
  # TurfMonsterRules — a test that derives its expectation from the same source
  # as the code proves only that the code equals itself.
  FALCONS_FIELD  = "#000000".freeze # card_background: the gradient's mid stop
  FALCONS_MASCOT = "#A71930".freeze # card_mascot: the "Falcons" wordmark
  STEELERS_LIGHT = "#FFB612".freeze # the PIT chip on Atlanta's dark field

  setup do
    @falcons = team!("atlanta-falcons", "Atlanta", "Falcons", "ATL", "🦅",
                     dark: FALCONS_FIELD, light: FALCONS_MASCOT)
    @steelers = team!("pittsburgh-steelers", "Pittsburgh", "Steelers", "PIT", "⚙️",
                      dark: "#101820", light: STEELERS_LIGHT)
  end

  test "an example card wears its team's own gradient and accent" do
    get turf_monster_v1_path

    assert_response :success
    card = falcons_card
    assert card, "the Atlanta card must render"

    style = card["style"].to_s
    assert_includes style, "linear-gradient", "the card field is the team gradient, not a flat fill"
    assert_includes style.downcase, FALCONS_FIELD.downcase,
                    "the gradient's mid stop is the team's own card_background"

    mascot = card.css("p").find { |node| node.text.strip == "Falcons" }
    assert mascot, "the card names the mascot"
    assert_includes mascot["style"].to_s.downcase, FALCONS_MASCOT.downcase,
                    "the mascot wears the team accent"
  end

  # The opponent chips are the half a "colour the six picks" fix would miss:
  # each one wears the OPPONENT's colour, chosen against the host field
  # (TeamColorsHelper#opponent_label_color).
  test "opponent chips wear the opponent's own color, not the host's" do
    get turf_monster_v1_path

    assert_response :success
    chip = falcons_card.css("span").find { |node| node.text.strip == "PIT" }
    assert chip, "Atlanta's week-one opponent chip must render"

    assert_includes chip["style"].to_s.downcase, STEELERS_LIGHT.downcase,
                    "on a dark host field the chip takes the opponent's LIGHT color"
    assert_not_includes chip["style"].to_s.downcase, FALCONS_MASCOT.downcase,
                        "the chip must not inherit the host team's accent"
  end

  # A slug the DB has never heard of must degrade, not 500 — the page is public
  # and a team row is not its to guarantee.
  test "the page still renders when a team row is missing" do
    Team.where(slug: TurfMonsterRules.team_slugs).delete_all

    get turf_monster_v1_path

    assert_response :success
    assert_select '[data-test="turf-monster-rules"]'
    # The derived numbers do not depend on a Team row, so they must survive it.
    assert_match(/1\.8/, response.body, "the multiplier is derived, not read off the team")
  end

  private

  def falcons_card
    css_select('[data-test="turf-monster-rules"] div').find do |node|
      node.css("p").any? { |p| p.text.strip == "Falcons" } && node["style"].to_s.include?("linear-gradient")
    end
  end

  def team!(slug, location, mascot, short_name, emoji, dark:, light:)
    Team.find_or_create_by!(slug: slug) do |team|
      team.name = "#{location} #{mascot}"
      team.location = location
      team.mascot = mascot
      team.short_name = short_name
      team.emoji = emoji
      team.league = "nfl"
      team.color_dark = dark
      team.color_light = light
      team.color_disposition = "dark"
    end
  end
end
