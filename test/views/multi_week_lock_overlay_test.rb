require "test_helper"

# THE LOCK ON A TEAM WHOSE GAME HAS STARTED.
#
# It used to be a glyph INSIDE the card button. `.holo-card > *` makes every
# child of that button position:relative, so the glyph's `absolute` never took:
# it sat on a line of its own and a locked card stood taller than the cards
# beside it. It now lives outside the button, as a sibling overlay on the
# wrapper, which CSS reveals on hover with the reason spelled out.
#
# Asserted on the contest PAGE, not on a bare partial render: what matters is
# where the overlay lands in the document the board actually ships.
# The measured half of this — equal heights, visible on hover — is a browser
# claim and lives in e2e/game_started_lock.spec.js.
class MultiWeekLockOverlayTest < ActionDispatch::IntegrationTest
  setup do
    @contest = contests(:one)
    span = Slate.create!(name: "NFL 2026 Weeks 1-2", slug: "nfl-2026-weeks-1-2", week: 1)
    span_row!(span, "team-a", "team-b", week: 1, kickoff: 1.hour.ago)       # started
    span_row!(span, "team-a", "team-d", week: 2, kickoff: 8.days.from_now)
    span_row!(span, "team-c", "team-e", week: 1, kickoff: 1.day.from_now)   # not started
    span_row!(span, "team-c", "team-f", week: 2, kickoff: 8.days.from_now)
    @contest.update!(slate: span)
    assert @contest.multi_week?, "the team card only renders on a span board"
  end

  def span_row!(slate, team, opponent, week:, kickoff:)
    game = Game.create!(home_team_slug: team, away_team_slug: opponent, kickoff_at: kickoff, status: "scheduled")
    SlateMatchup.create!(slate: slate, team_slug: team, opponent_team_slug: opponent, game_slug: game.slug,
                         week: week, expected_score: 21.0, turf_score: 2.0, rank: 1, status: "pending")
  end

  def card_for(mascot_or_name)
    css_select(".holo-wrap").find { |wrap| wrap.at_css("button.holo-card")["aria-label"].include?(mascot_or_name) }
  end

  test "a locked team carries the Game Started overlay as a sibling of its card" do
    get contest_page_path(@contest)
    assert_response :success

    wrap = card_for(teams(:team_a).name)
    assert wrap, "team-a's card must be on the board"
    assert wrap.at_css("button.holo-card")["disabled"], "team-a's first game has kicked off, so its card is locked"

    overlay = wrap.css("> [data-test='game-started-overlay']")
    assert_equal 1, overlay.size, "the overlay sits on the wrapper, beside the button"
    assert_match(/Game Started/, overlay.text)
    assert_includes overlay.text, "\u{1F512}"
    assert_equal "true", overlay.first["aria-hidden"], "the reason is in the button's own accessible name instead"
    assert_match(/locked, game started/, wrap.at_css("button.holo-card")["aria-label"])
  end

  test "nothing about the lock is left inside the card's own flow" do
    get contest_page_path(@contest)

    button = card_for(teams(:team_a).name).at_css("button.holo-card")

    assert_empty button.css("[data-test='game-started-overlay']")
    assert_not_includes button.text, "\u{1F512}",
                        "a lock inside the button takes a line of its own (.holo-card > * is position:relative)"
  end

  test "a team whose game has not started gets no overlay" do
    get contest_page_path(@contest)

    wrap = card_for(teams(:team_c).name)

    assert wrap, "team-c's card must be on the board"
    assert_nil wrap.at_css("button.holo-card")["disabled"]
    assert_empty wrap.css("[data-test='game-started-overlay']")
    assert_no_match(/game started/, wrap.at_css("button.holo-card")["aria-label"])
  end

  test "the overlay's hover rule ships in the stylesheet" do
    css = Rails.root.join("app/assets/tailwind/application.css").read

    assert_match(/\.tm-lock-overlay\s*\{[^}]*opacity:\s*0;[^}]*pointer-events:\s*none;/m, css)
    assert_match(/\.holo-wrap:hover > \.tm-lock-overlay\s*\{[^}]*opacity:\s*1;/m, css)
  end
end
