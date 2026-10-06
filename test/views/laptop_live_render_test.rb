require "test_helper"

# [component] + [integration] The hero laptop's live-page snapshot, rendered
# from the live page's own partials as a SIGNED-OUT visitor sees it: a live
# contest, a finished one, and none (the lobby fallback). Then the privacy
# rules for a public page, checked signed in as an admin: none of the viewer's
# identity, no player-typed chat, no email or wallet labels.
class LaptopLiveRenderTest < ActionDispatch::IntegrationTest
  setup do
    SeasonConfig.set_main_contest!(nil)
    Message.delete_all
    Selection.delete_all
    Entry.delete_all
    Contest.delete_all
    @slate = Slate.create!(name: "NFL 2026 Weeks 4-6", slug: "nfl-2026-weeks-4-6-laptop", sport: "nfl",
                           starts_at: 20.days.ago)
  end

  def nfl_contest(slug, starts_at:, status: "open")
    Contest.create!(name: slug.titleize, slug: slug, status: status, entry_fee_cents: 1900, max_entries: 29,
                    contest_type: "standard", slate: @slate, starts_at: starts_at)
  end

  def enter(contest, user, score)
    contest.entries.create!(user: user, status: :active).tap { |e| e.update_column(:score, score) }
  end

  def laptop
    get turf_monster_v2_path
    assert_response :success
    node = css_select('[data-test="laptop-mock"]').first
    assert node, "the laptop renders"
    node
  end

  test "a contest being played shows its live page from the real partials, signed out" do
    contest = nfl_contest("weeks-4-6-live", starts_at: 2.days.ago)
    enter(contest, users(:jordan), 120.5)
    enter(contest, users(:sam), 140.0)

    live = laptop.at_css('[data-test="laptop-live"]')
    assert live, "the live snapshot draws"
    assert live.key?("x-ignore"), "static: Alpine never walks it"
    assert_empty live.css("script, turbo-cable-stream-source"), "no code and no cable subscription"
    assert_includes live.text, "Weeks 4 6 Live"
    assert live.at_css('a[href$="/contest"]') || live.text.include?("← Contest"), "the live header's back link"
    assert_includes live.text, "Sign in", "the navbar is the signed-out chrome"

    board = live.at_css('[data-test="laptop-live-leaderboard"]')
    assert_operator board.text.index("sam_test"), :<, board.text.index("jordan_test"), "ranked by score"
    assert_includes board.text, "👑", "the crown on #1"
    # With Alpine ignored, the picks row a guest's desktop shows (dkFull) is
    # revealed statically and the narrow-column fan is hidden.
    assert board.css('[x-show="dkFull"]').any?
    assert board.css('[x-show="dkFull"]').none? { |n| n.key?("x-cloak") }
    assert board.css('[x-show="!dkFull"]').all? { |n| n["style"].to_s.include?("display: none") }
    first_payout = contest.payouts.values.max / 100.0
    assert_includes board.text, ActionController::Base.helpers.number_to_currency(first_payout), "#1's payout"
  end

  # THE GLOW. On the real page only the chip of the game being watched glows
  # (Alpine adds tt-chip-focused); the snapshot resolves that server-side, so
  # exactly one chip carries it, and the live page's styles (which turn every
  # other chip's glow off) ride along.
  test "exactly one games-strip chip is lit, the featured game's" do
    contest = nfl_contest("weeks-4-6-glow", starts_at: 2.days.ago)
    # Same week, so the live page's week window shows both.
    second = Game.create!(slug: "e-at-f-glow", home_team_slug: "team-f", away_team_slug: "team-e",
                          kickoff_at: games(:future_game).kickoff_at + 3.hours, status: "scheduled", venue: "Test Stadium")
    games = [games(:future_game), second]
    games.each do |g|
      SlateMatchup.create!(slate: @slate, team_slug: g.home_team_slug, opponent_team_slug: g.away_team_slug, game_slug: g.slug)
    end

    showcase = NextContest.live_showcase
    assert_equal contest, showcase.contest
    live = laptop.at_css('[data-test="laptop-live"]')
    chips = live.css('[data-test="live-game-chip"]')
    assert_operator chips.size, :>=, 2
    lit = chips.select { |c| c["class"].to_s.split.include?("tt-chip-focused") }
    assert_equal [showcase.focus_slug], lit.map { |c| c["data-game-slug"] }
    assert_includes live.to_html, ".tt-chip-focused", "the live page's chip styles are included"
  end

  # The collapsed (scrolled) navbar, and the strip drawn mid-rotation: with
  # more chips than fit, the carousel's copy is appended in the same order and
  # the track is offset so the lit chip's copy lands in the visible middle.
  test "the navbar is collapsed and an overflowing strip shows the lit chip mid-strip, in order" do
    contest = nfl_contest("weeks-4-6-strip", starts_at: 2.days.ago)
    kickoff = games(:future_game).kickoff_at
    # Distinct pairings of the six fixture teams (a game's slug derives from
    # its two teams), skipping the pairs other fixtures already use.
    pairs = Team.order(:slug).pluck(:slug).combination(2).reject do |a, b|
      [%w[team-a team-b], %w[team-c team-d], %w[team-e team-f]].include?([a, b])
    end
    pairs.first(9).each_with_index do |(home, away), i|
      g = Game.create!(slug: "strip-#{i}", home_team_slug: home, away_team_slug: away,
                       kickoff_at: kickoff + i.minutes, status: "scheduled", venue: "Test Stadium")
      SlateMatchup.create!(slate: @slate, team_slug: g.home_team_slug, opponent_team_slug: g.away_team_slug, game_slug: g.slug)
    end
    assert_equal contest, NextContest.live_showcase.contest

    live = laptop.at_css('[data-test="laptop-live"]')
    assert_match(/--nav-p: 1/, live.at_css("header[data-navbar-root]")["style"])

    track = live.at_css('[x-ref="track"]')
    slugs = track.css('[data-test="live-game-chip"]').map { |c| c["data-game-slug"] }
    half = slugs.size / 2
    assert_equal slugs.first(half), slugs.last(half), "the appended copy keeps the real order"
    focus = slugs.first(half).index(NextContest.live_showcase.focus_slug)
    expected = (half + focus - LaptopLiveSnapshot::FOCUS_SLOT) * LaptopLiveSnapshot::CHIP_PITCH
    assert_includes track["style"], "translateX(-#{expected}px)"
  end

  # THE LINK UNDER THE LAPTOP: real, focusable, outside the inert laptop, to
  # the snapshot contest's live page. Live: "Watch updates live". Finished:
  # "See the latest results". Neither: no link.
  test "the link under the laptop follows the snapshot contest" do
    live_contest = nfl_contest("weeks-4-6-link", starts_at: 2.days.ago)
    get turf_monster_v2_path
    link = css_select('[data-test="v2-watch-live"]').first
    assert_equal live_contest_path(live_contest), link["href"]
    assert_includes link.text, "Watch updates live"
    assert link.ancestors('[aria-hidden="true"], [inert]').empty?, "focusable: not inside the decorative laptop"

    live_contest.update_columns(status: "settled")
    get turf_monster_v2_path
    link = css_select('[data-test="v2-watch-live"]').first
    assert_includes link.text, "See the latest results"
    refute_includes link.text, "Watch updates live"

    Contest.delete_all
    get turf_monster_v2_path
    assert_empty css_select('[data-test="v2-watch-live"]')
  end

  test "with nothing live, the most recently finished NFL contest shows" do
    nfl_contest("older-final", starts_at: 30.days.ago, status: "settled")
    nfl_contest("newer-final", starts_at: 10.days.ago, status: "settled")
    showcase = NextContest.live_showcase
    assert_equal "newer-final", showcase.contest.slug
    refute showcase.live?
    assert_includes laptop.at_css('[data-test="laptop-live"]').text, "Newer Final"
  end

  test "with no live or finished contest, the laptop falls back to the lobby" do
    nfl_contest("upcoming", starts_at: 5.days.from_now)
    assert_nil NextContest.live_showcase
    node = laptop
    assert_nil node.at_css('[data-test="laptop-live"]')
    assert node.at_css('[data-test="laptop-lobby-row"]') || node.at_css('[data-test="laptop-lobby-next-drop"]')
  end

  # PRIVACY, signed in as an admin with a username, email, wallet and seeds.
  test "signed in, the laptop shows nothing of the viewer and no player-typed chat" do
    viewer = users(:alex)
    viewer.update_columns(web3_solana_address: "So1anaViewerAddre55xxxxxxxxxxxxxxxxxxxxxxxx", seeds: 777)
    contest = nfl_contest("weeks-4-6-private", starts_at: 2.days.ago)
    nameless = users(:casey)
    nameless.update_columns(username: nil)
    enter(contest, nameless, 99.0)
    enter(contest, viewer, 50.0) # even the viewer's own entry must not read as theirs
    Message.create!(contest: contest, user: users(:jordan), body: "secret chat body do not show")
    Message.create!(contest: contest, user: users(:jordan), system: true, body: "🎉 jordan_test joined the contest")

    log_in_as(viewer)
    live = laptop.at_css('[data-test="laptop-live"]')
    html = live.to_html
    ["secret chat body", viewer.email, viewer.web3_solana_address, nameless.email.to_s,
     nameless.email.to_s.split("@").first.capitalize, "Contest JSON"].reject(&:blank?).each do |bit|
      refute_includes html, bit, "the laptop must not show #{bit.inspect}"
    end
    assert_includes live.text, "Sign in", "signed-out chrome even when the viewer is signed in"
    refute_includes live.text, "Add 2nd Entry"
    assert_empty live.css(".chat-admin"), "no admin chat controls revealed"
    assert_includes live.at_css('[data-test="laptop-live-chat"]').text, "jordan_test joined the contest",
                    "system join lines do render"
    assert_includes live.at_css('[data-test="laptop-live-leaderboard"]').text, "Player 1",
                    "a player with no username is Player N, never an email or wallet"
  end
end
