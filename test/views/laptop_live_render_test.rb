require "test_helper"

# [integration] The hero laptop on /turf-monster-v2: the FICTIONAL contest's
# live page (LaptopFictionalShowcase), rendered from the live page's own
# partials as a SIGNED-OUT visitor sees it, whatever real contests, entries and
# chat the database holds. No real contest name, username, email, wallet or
# chat line ever reaches it. The link UNDER the laptop still follows the real
# contests (NextContest.live_contest).
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

  # A real contest being played, with real entries and chat: the laptop shows
  # none of it, only the fictional showcase.
  def real_contest_with_players
    contest = nfl_contest("weeks-4-6-live", starts_at: 2.days.ago)
    game = games(:future_game)
    SlateMatchup.create!(slate: @slate, team_slug: game.home_team_slug, opponent_team_slug: game.away_team_slug,
                         game_slug: game.slug)
    enter(contest, users(:jordan), 120.5)
    enter(contest, users(:sam), 140.0)
    Message.create!(contest: contest, user: users(:jordan), body: "secret chat body do not show")
    Message.create!(contest: contest, user: users(:jordan), system: true, body: "🎉 jordan_test joined the contest")
    contest
  end

  test "with a real contest live, the laptop draws the fictional showcase, signed out" do
    real = real_contest_with_players

    live = laptop.at_css('[data-test="laptop-live"]')
    assert live, "the live snapshot draws"
    assert live.key?("x-ignore"), "static: Alpine never walks it"
    assert_empty live.css("script, turbo-cable-stream-source"), "no code and no cable subscription"
    assert_includes live.text, "Turf Monster Showcase"
    assert_includes live.text, "NFL Sunday"
    refute_includes live.text, real.name
    refute_includes live.text, @slate.name
    assert_includes live.text, "Sign in", "the navbar is the signed-out chrome"
    assert_equal %w[showcase-mason showcase-turf],
                 live.css('[data-test="laptop-live-leaderboard"] [data-entry-slug]').map { |r| r["data-entry-slug"] }.uniq
    assert_includes live.at_css('[data-test="laptop-live-leaderboard"]').text, "👑", "the crown on #1"
  end

  # The leaderboard runs on a Stimulus controller on the real page. In the
  # snapshot none may connect, so its layout is resolved to the 1280px page:
  # the full row of six shows, the narrow fan does not, nothing is unfolded.
  test "the laptop's leaderboard is static: no controller, the full pill row shown" do
    board = laptop.at_css('[data-test="laptop-live"] [data-test="laptop-live-leaderboard"]')

    assert_empty laptop.css("[data-controller], [data-action]"), "a Stimulus controller would connect inside the laptop"
    assert_not_empty board.css('[data-leaderboard-target="full"]')
    board.css('[data-leaderboard-target="full"], [data-leaderboard-target="more"]').each { |node| assert_not node.key?("hidden") }
    board.css('[data-leaderboard-target="narrow"], [data-leaderboard-target="tail"], [data-leaderboard-target="less"]').each do |node|
      assert node.key?("hidden"), node.to_html[0, 100]
    end
  end

  test "no real username, email or chat line reaches the laptop, even with real entries" do
    real_contest_with_players
    html = laptop.to_html
    User.where.not(username: [nil, ""]).pluck(:username).each do |name|
      refute_match(/(?<![\w-])#{Regexp.escape(name)}(?![\w-])/, html, "no real username: #{name}")
    end
    User.where.not(email: [nil, ""]).pluck(:email).each { |email| refute_includes html, email }
    refute_includes html, "secret chat body"
    refute_includes html, "joined the contest"
  end

  test "exactly one games-strip chip is lit, the featured 49ers at Cowboys game" do
    live = laptop.at_css('[data-test="laptop-live"]')
    chips = live.css('[data-test="live-game-chip"]')
    lit = chips.select { |c| c["class"].to_s.split.include?("tt-chip-focused") }.map { |c| c["data-game-slug"] }.uniq
    assert_equal [LaptopFictionalShowcase::FOCUS_SLUG], lit
    assert_includes live.to_html, ".tt-chip-focused", "the live page's chip styles are included"
    navbar = live.at_css('header[data-test="laptop-navbar"]')
    assert_match(/--nav-p: 1/, navbar["style"], "the collapsed navbar")
    assert_empty live.css("[data-navbar-root]"), "the page's own navbar is the only navbar root"
    # The picture of the header carries none of the live header's hooks (it
    # renders as a preview): the page's scroll timeline would stick and shrink
    # it inside the hero, and a data-pin would make it a second nav layer of
    # the page's pinned stack.
    %w[data-nav-timeline data-pin data-studio-controller].each do |attr|
      refute navbar.key?(attr), "the laptop navbar carries no #{attr}"
    end
    assert_empty live.css("[data-pin], [data-nav-timeline]")
  end

  # THE LINK UNDER THE LAPTOP: real, focusable, outside the inert laptop, to
  # the latest REAL contest's live page, independent of the fictional laptop.
  test "the link under the laptop follows the real contests, not the laptop" do
    live_contest = nfl_contest("weeks-4-6-link", starts_at: 2.days.ago)
    get turf_monster_v2_path
    link = css_select('[data-test="v2-watch-live"]').first
    assert_equal live_contest_path(live_contest), link["href"]
    assert_includes link.text, "Watch updates live"
    assert link.ancestors('[aria-hidden="true"], [inert]').empty?, "focusable: not inside the decorative laptop"
    assert css_select('[data-test="laptop-live"]').any?, "the fictional laptop draws beside it"

    live_contest.update_columns(status: "settled")
    get turf_monster_v2_path
    link = css_select('[data-test="v2-watch-live"]').first
    assert_includes link.text, "See the latest results"
    refute_includes link.text, "Watch updates live"

    Contest.delete_all
    get turf_monster_v2_path
    assert_empty css_select('[data-test="v2-watch-live"]')
    assert css_select('[data-test="laptop-live"]').any?, "with no real contest at all, the laptop still draws"
  end

  # PRIVACY, signed in as an admin with a username, email, wallet and seeds.
  test "signed in, the laptop shows nothing of the viewer" do
    viewer = users(:alex)
    viewer.update_columns(web3_solana_address: "So1anaViewerAddre55xxxxxxxxxxxxxxxxxxxxxxxx", seeds: 777)
    enter(real_contest_with_players, viewer, 50.0)

    log_in_as(viewer)
    live = laptop.at_css('[data-test="laptop-live"]')
    html = live.to_html
    [viewer.username, viewer.email, viewer.web3_solana_address, "Contest JSON"].reject(&:blank?).each do |bit|
      refute_includes html, bit, "the laptop must not show #{bit.inspect}"
    end
    assert_includes live.text, "Sign in", "signed-out chrome even when the viewer is signed in"
    refute_includes live.text, "Add 2nd Entry"
    assert_empty live.css(".chat-admin"), "no admin chat controls revealed"
  end
end
