require "test_helper"

# [component] The contest live page, as it actually renders.
#
# The page's whole job is to say what CHANGED, and almost everything it says is
# said in markup this test can see: the tile it draws each game with, the marks
# that identify the reader's own team and own entry, the hooks the ranking
# script keys off. What it cannot see is the motion — that is the operator's
# call at the QA stop — so every assertion here is about the STATE the motion
# reads from, which is the half that can silently rot.
class ContestLiveRenderTest < ActionDispatch::IntegrationTest
  setup do
    @contest = contests(:one)
    # live? is locked? && !settled?, and locked? is derived from starts_at.
    @contest.update!(starts_at: 1.hour.ago, status: "open")

    # Brand colours pinned, because the tile's entire visual argument is that a
    # game is drawn in its two teams' own hues.
    #
    # COLOURS ONLY — deliberately not the name. Team includes Sluggable, which
    # re-stamps the slug on every save, and slate_matchups join to teams BY SLUG.
    # Renaming team-a here silently orphaned every matchup pointing at it, and
    # the page died on `card_background for nil` two partials away from the edit.
    teams(:team_a).update!(color_dark: "#241773", color_light: "#9E7C0C", color_disposition: "dark")
    teams(:team_b).update!(league: "nfl", sport: "football")

    @played = games(:past_game)        # team-a vs team-b, completed
    @upcoming = games(:future_game)    # team-c vs team-d, scheduled
    slate_matchups(:m1).update!(game_slug: @played.slug)
    slate_matchups(:m2).update!(game_slug: @played.slug)
    slate_matchups(:m3).update!(game_slug: @upcoming.slug)

    # FIXTURES SKIP CALLBACKS, so the slug Sluggable stamps in before_save on
    # create was never written — and the slug is precisely what the ranking
    # script uses to recognise a row across a full replacement. Re-saving does
    # not fix it (an unchanged record writes nothing), so stamp it the way the
    # create path would. Distinct scores too: two equal scores trip the board's
    # `everyone_equal` branch, which reorders to float the viewer and would make
    # every rank assertion below depend on who is signed in.
    @mine = entries(:one)              # alex
    @theirs = entries(:two)            # jordan
    @mine.update!(score: 12.5)
    @theirs.update!(score: 4.0)
    [@mine, @theirs].each { |entry| entry.update_column(:slug, entry.name_slug) }

    @mine.selections.create!(slate_matchup: slate_matchups(:m1))   # team-a
    @theirs.selections.create!(slate_matchup: slate_matchups(:m3)) # team-c
  end

  def get_live(as: nil)
    log_in_as(as) if as
    get live_contest_path(@contest)
  end

  # The port itself: this page draws the SAME tile the league scoreboard draws.
  # Assert on the league board's own marker, so a future divergence — someone
  # reintroducing a contest-only card — fails here rather than being noticed
  # months later in a screenshot.
  test "draws each game with the league scoreboard's tile" do
    get_live

    assert_response :success
    assert_select "[data-test=?]", "live-game-tile", minimum: 2
  end

  test "paints a game in its two teams' brand hues" do
    get_live

    assert_match(/linear-gradient\([^)]*#241773/i, response.body,
      "the tile should wear the team's own field colour, not a neutral card")
  end

  # THE STICKY STATE. Contest::LiveBroadcast sends one payload to every
  # subscriber, so anything viewer-specific inside a broadcast target is gone
  # after the first score. This list lives outside every target precisely so the
  # page can put the mark back — if it stops being rendered, the viewer's own row
  # is marked on first paint and anonymous for the rest of the contest.
  test "publishes the viewer's own entries outside every broadcast target" do
    get_live(as: users(:alex))

    shell = css_select("#contest_#{@contest.id}_viewer").first
    assert_equal @mine.reload.slug, shell["data-entry-slugs"]
  end

  test "publishes empty sticky state for a signed-out reader" do
    get_live

    shell = css_select("#contest_#{@contest.id}_viewer").first
    assert_equal "", shell["data-entry-slugs"]
  end

  # The ranking hooks. rank and score are what "who moved" is derived FROM;
  # entry-slug is what makes the derivation possible across a full replacement.
  test "each leaderboard row carries its identity, rank and score" do
    get_live

    assert_select "[data-role=entry-row]", count: 2
    row = css_select("[data-role=entry-row][data-entry-slug='#{@mine.reload.slug}']").first
    assert row, "the viewer's entry should be identifiable by its slug"
    assert_equal "1", row["data-rank"]
    assert_equal "12.5", row["data-score"]
    assert_select "[data-role=entry-row] [data-role=entry-score]", count: 2
  end

  # A first render has nothing to compare against, and a board that claims
  # movement it never observed is worse than one that claims none.
  test "renders the movement slot empty on a first paint" do
    get_live

    assert_select "[data-role=rank-move]", count: 2
    assert_select "[data-role=rank-move]" do |slots|
      slots.each { |slot| assert_equal "", slot.text.strip }
    end
  end

  # THE LAYOUT: a strip of every game across the top, one of them shown at full
  # size in the left column, the ranking down the right.
  test "renders one chip per game in the strip" do
    get_live

    assert_select "[data-test=?]", "live-game-chip", count: 2
  end

  # Every game is rendered into the focus panel and all but one is hidden, so
  # switching is instant and a broadcast refreshes the fifteen you might switch
  # to as well as the one you are watching. The inline display:none is what
  # keeps the page from opening as a column of sixteen games — Alpine boots
  # after first paint, so x-show alone is too late.
  test "renders every game into the focus panel with exactly one visible" do
    get_live

    assert_select "[data-test=?]", "live-focus-game", count: 2
    shown = css_select("[data-test='live-focus-game']").reject { |el| el["style"].to_s.include?("display: none") }
    assert_equal 1, shown.size, "exactly one focus tile should be visible on first paint"
  end

  # It opens on what is being played; with nothing live, on what is next. The
  # strip is laid out in the same order, so the opening game is the chip at the
  # far left rather than one buried mid-row.
  test "opens focused on the next game when nothing is live" do
    get_live

    shown = css_select("[data-test='live-focus-game']").reject { |el| el["style"].to_s.include?("display: none") }
    assert_equal @upcoming.slug, shown.first["data-focus-slug"]
    assert_select "[x-data=?]", "{ focus: '#{@upcoming.slug}' }"
  end

  # The chip and the full tile draw the same game, and a score has to light both.
  # The page's script queries all matching rows rather than the first, which only
  # works while both carry the hooks.
  # The centrepiece is drawn LARGE — same partial, same hooks, bigger type.
  test "draws the focused game at hero size" do
    get_live

    assert_select "[data-test='live-focus-game'] [data-role=score].text-5xl", minimum: 1
  end

  test "chip and focus tile share the animation hooks" do
    get_live

    %w[live-game-chip live-focus-game].each do |marker|
      assert_select "[data-test='#{marker}'] [data-team-slug='team-a'] [data-role=score]",
                    { minimum: 1 }, "#{marker} should expose a score the scoring animation can find"
    end
  end

  # The banner is the league board's own element, rendered from the same partial.
  # Its CSS already lived in live/_score_animations, so a page that styled a
  # banner it had no element for would have looked fine and announced nothing.
  test "draws the shared scoring banner" do
    get_live

    assert_select "#nfl-score-overlay #nfl-score-banner", count: 1
    assert_select "#nfl-score-label", count: 1
    assert_select "#nfl-score-line", count: 1
  end

  # The cut line sits after the last PAYING rank, not after the last entry —
  # contest :one is a standard format, which pays five.
  test "draws the money line after the last paying rank" do
    get_live

    assert_equal 5, @contest.payouts.keys.map(&:to_i).max
    assert_select "[data-test=?]", "leaderboard-money-line", count: 1
  end


  # SCORE THE FIXTURE GAME WITHOUT ORPHANING IT.
  #
  # Game includes Sluggable, so every save re-stamps the slug from the two team
  # slugs — and these fixtures carry hand-written slugs ("past-game") that do not
  # match. Goal's after_create saves the game to recompute its score, which
  # renames it mid-write and leaves the goal pointing at a slug nothing has. The
  # slate matchups point at the old slug too.
  #
  # So: stamp the slug Sluggable wants FIRST, repoint the matchups at it, and
  # only then score. The same trap the setup above already documents for teams.
  def score!(game, **attrs)
    if game.slug != game.name_slug
      old = game.slug
      game.update_column(:slug, game.name_slug)
      SlateMatchup.where(game_slug: old).update_all(game_slug: game.slug)
      game.reload
    end
    game.goals.create!({ team_slug: teams(:team_a).slug, points: 6,
                         scoring_type: "touchdown", scorer_name: "Josh Allen" }.merge(attrs))
  end

  # ── THE SCORER REVEAL ─────────────────────────────────────────────────────
  #
  # The card the focus panel swaps its events list for. What this pins is the
  # STATE the animation reads from — the hooks, and which tiles get one — since
  # the motion itself is the operator's call at the QA stop.

  test "the hero tile carries a scorer card, hidden at rest" do
    score!(@played)
    get_live

    assert_select "[data-role=scorer-card]" do |cards|
      assert cards.any?, "the focus tile should carry a card"
      cards.each do |card|
        assert_equal "true", card["aria-hidden"],
          "the card must be hidden until a score reveals it"
      end
    end
  end

  # The card is EMPTY on the server. The tile is re-rendered by every broadcast,
  # so a card holding the last score would flash on screen for one frame each
  # time some other game scored.
  test "the card ships empty, not pre-filled with the latest score" do
    score!(@played)
    get_live

    assert_select "[data-role=scorer-name]" do |slots|
      slots.each { |slot| assert_equal "", slot.text.strip, "the card must not name a scorer server-side" }
    end
    assert_select "[data-role=scorer-card] img[src]", { count: 0 },
      "no headshot should be committed to the markup"
  end

  test "the card lives inside the events frame, so it can take the list's place" do
    score!(@played)
    get_live

    assert_select "[data-role=event-feed-frame] [data-role=scorer-card]", { minimum: 1 },
      "the card must be a child of the frame — that is what lets one class swap both"
  end

  test "every slot the script writes into is present" do
    score!(@played)
    get_live

    # A missing slot would throw inside paintScorerCard and wedge the chain, the
    # same way a deleted helper once did to flushChain.
    %w[scorer-headshot scorer-initials scorer-headline scorer-name
       scorer-detail scorer-location scorer-mascot].each do |role|
      assert_select "[data-role=scorer-card] [data-role=#{role}]", { minimum: 1 },
        "paintScorerCard writes into [data-role=#{role}]"
    end
  end

  # A game with no scores has no events rail, and the card lives in the rail. The
  # first touchdown of a game therefore arrives before its own container — the
  # page re-applies the reveal after the broadcast, which is what makes that
  # work, and this pins the server half of it.
  test "a game with no scores yet renders no rail and no card" do
    assert_empty @upcoming.goals
    get_live

    assert_select "[data-focus-slug=?] [data-role=scorer-card]", @upcoming.slug, count: 0
  end


  # ── THE WHEEL ─────────────────────────────────────────────────────────────

  # Two card panes, not one. A single card repainted in place made the second
  # event of a chain jump — the content swapped under a pane that never moved.
  # Two panes give the next event somewhere to be built off screen.
  test "the rail carries a track with a list pane and TWO card panes" do
    score!(@played)
    get_live

    assert_select "[data-role=event-feed-frame] .tt-event-track", { minimum: 1 },
      "the panes ride one track — that is what makes the swap a roll"
    assert_select "[data-role=event-feed-frame] [data-role=scorer-pane]", count: 2
    assert_select "[data-role=scorer-pane][data-pane=a]", { minimum: 1 }
    assert_select "[data-role=scorer-pane][data-pane=b]", { minimum: 1 }
  end

  # The points chip was dropped deliberately: the banner already shouts "+6",
  # and the card spent width on the one fact a reader can also read off the
  # score beside it.
  test "the card carries no points chip" do
    score!(@played)
    get_live

    assert_select "[data-role=scorer-card] [data-role=scorer-points]", count: 0
  end

  # The banner is SHARED with the league board, whose feed carries no scorer. So
  # it keeps both slots: the avatar the contest page fills, and the points chip
  # the league board still falls back to. Dropping the chip outright would have
  # taken two league specs with it.
  test "the shared banner keeps an avatar slot AND the points fallback" do
    get_live

    assert_select "#nfl-score-banner #nfl-score-avatar", count: 1
    assert_select "#nfl-score-banner #nfl-score-points", count: 1
  end

  # ── THE BANNER'S SHARED SLOTS ─────────────────────────────────────────────
  #
  # The scoring banner and the rank summary are the SAME element, repainted.
  # That sharing is deliberate and free, but it has now produced three bugs from
  # state surviving a repaint — the latest being the rank summary inheriting the
  # touchdown scorer's headshot for its full six seconds, because
  # paintRankBanner repainted four slots and the diff had made it five.
  #
  # A render test cannot run the repaint, so it pins the CONTRACT the repaint has
  # to honour: the script must clear every slot it does not own, and the script
  # must be the only thing that fills them.
  test "the banner ships with every slot empty" do
    get_live

    %w[nfl-score-emoji nfl-score-label nfl-score-team nfl-score-points nfl-score-line].each do |id|
      assert_select "##{id}" do |els|
        assert_equal "", els.first.text.strip, "#{id} must ship empty — the script owns it"
      end
    end
    assert_select "#nfl-score-avatar[src]", { count: 0 },
      "the banner's avatar must ship with no source"
  end

  # THE INVARIANT, CHECKED AGAINST THE SCRIPT ITSELF.
  #
  # An earlier version of this test listed the five slot ids and asserted the
  # BANNER PARTIAL rendered each one. That partial is not where the bug lives:
  # it was byte-identical before and after the fix, so the test passed on the
  # bug it was written to catch. A test that cannot fail is worse than no test,
  # because it reads as coverage.
  #
  # The real contract is between the two FUNCTIONS that share the element:
  # paintBanner fills it for a score, paintRankBanner repaints it for the rank
  # summary, and the summary is drawn WITHOUT the overlay hiding in between (see
  # advanceChain). So every slot the score writes, the summary must also write —
  # or it inherits it. That is exactly how the summary ended up wearing a
  # touchdown scorer's headshot for six seconds.
  #
  # Structural, and deliberately so: it reads each function's own body out of
  # the script and compares the sets. Add a sixth slot to paintBanner and forget
  # paintRankBanner, and this goes red naming it.
  SCRIPT = Rails.root.join("app/views/contests/_live_script.html.erb")

  # The body of a top-level `function name(...) { ... }` in the script, matched
  # by brace depth rather than by a regex, so a nested block cannot end it early.
  def function_body(source, name)
    start = source.index("function #{name}(")
    assert start, "#{name} not found in the script — was it renamed?"

    open_brace = source.index("{", start)
    depth = 0
    open_brace.upto(source.length - 1) do |i|
      depth += 1 if source[i] == "{"
      depth -= 1 if source[i] == "}"
      return source[open_brace..i] if depth.zero?
    end
    flunk "#{name} has unbalanced braces"
  end

  # COMMENTS ARE STRIPPED BEFORE SCANNING, and that is not a nicety.
  #
  # The first cut of this test scanned the raw body, and the mutation that
  # reintroduces the real bug did NOT turn it red: the explanatory comment above
  # the fix still said "#nfl-score-avatar", so the id was found in PROSE and the
  # assertion passed on code that no longer touched the slot. A test satisfied by
  # a comment is a test that fails the moment someone rewords a comment, and
  # passes the moment someone deletes the code it describes.
  def code_only(body)
    body.gsub(%r{/\*.*?\*/}m, " ").gsub(%r{//[^\n]*}, " ")
  end

  def banner_slots_written_by(source, name)
    code_only(function_body(source, name)).scan(/nfl-score-[a-z]+/).uniq.to_set
  end

  test "the rank summary repaints every banner slot a score writes" do
    source = File.read(SCRIPT)

    by_score = banner_slots_written_by(source, "paintBanner")
    by_rank  = banner_slots_written_by(source, "paintRankBanner")

    assert by_score.any?, "paintBanner writes no banner slots — the parse is wrong"

    missed = by_score - by_rank
    assert_empty missed,
      "paintRankBanner must account for every slot paintBanner fills, or the " \
      "summary inherits it — the overlay never hides between the two. Missed: " \
      "#{missed.to_a.sort.join(", ")}"
  end

  # And the slots they agree on are really in the markup — the pair could be
  # consistent with each other and both wrong about the element.
  test "every slot the script writes exists in the banner" do
    source = File.read(SCRIPT)
    get_live

    banner_slots_written_by(source, "paintBanner").each do |id|
      assert_select "#nfl-score-banner ##{id}", { count: 1 },
        "the script writes ##{id}, so the banner must render it"
    end
  end

  # The avatar ships hidden: an <img> with no src that is not hidden renders as a
  # broken-image glyph in the banner's own layout.
  test "the banner avatar ships hidden" do
    get_live

    assert_select "#nfl-score-avatar" do |els|
      assert_includes els.first["class"].to_s.split, "hidden"
    end
  end

  # ── THE GAMES STRIP SCROLLS ───────────────────────────────────────────────
  #
  # The strip auto-rotates, and used to do it by animating a `transform` inside
  # an `overflow-hidden` viewport — which meant a reader could not reach a game
  # the rotation had not got to yet. The position is now owned by the native
  # scroll offset, so the reader and the rotation move the same number and the
  # handover costs nothing.
  test "the strip viewport scrolls horizontally" do
    get_live

    assert_select "[x-ref=viewport]" do |els|
      classes = els.first["class"].to_s.split
      assert_includes classes, "overflow-x-auto",
        "the reader must be able to scroll the strip by hand"
    end
  end

  # overflow-y MUST stay hidden and the py-2 MUST stay. The selected chip's glow
  # ring paints outside its own box; the padding is what stops the viewport
  # slicing it flat, and an `overflow: auto` one-liner silently takes both away.
  test "the strip still clips vertically and keeps room for the ring" do
    get_live

    assert_select "[x-ref=viewport]" do |els|
      classes = els.first["class"].to_s.split
      assert_includes classes, "overflow-y-hidden", "the ring is clipped vertically by design"
      assert_includes classes, "py-2", "and the padding is what keeps it from being sliced"
    end
  end

  # A reader who scrolls has said where they want to be far more clearly than a
  # hover does, so the rotation stands down for good rather than pausing. These
  # are the four interactions that mean "a person did this" — a `scroll` event
  # would not do, because the rotation fires that itself.
  test "a real interaction stands the rotation down" do
    get_live

    assert_select "[x-ref=viewport]" do |els|
      markup = els.first.to_s
      %w[@wheel @touchstart.passive @pointerdown @keydown].each do |handler|
        assert_includes markup, handler,
          "#{handler} must hand the strip to the reader"
      end
      assert_includes markup, "standDown()",
        "and it must stand DOWN, not merely pause — resume() refuses afterwards"
      assert_includes markup, "remember()",
        "and every movement must be recorded, or a score forgets where the reader was"
    end
  end

  # THE STATE MUST NOT LIVE WHERE THE BROADCAST CAN REACH IT.
  #
  # Contest::LiveBroadcast#replace_games re-renders EXACTLY this partial into
  # #contest_<id>_games on every score, so anything the partial declares is
  # rebuilt from scratch each time anyone scores. While the reader's scroll
  # offset and stand-down lived on the component inside it, both reset on every
  # touchdown — the strip jumped back to 0 and started rotating again under
  # someone who had parked it. The declaration therefore belongs to the page,
  # outside the target, and this is the seam that keeps it there.
  test "the strip's memory is declared outside the broadcast target" do
    strip = render_strip_partial
    refute_includes strip, "gamesStripMemory =",
      "declaring the memory inside the re-rendered partial resets it on every score"

    get_live
    assert_includes response.body, "window.gamesStripMemory",
      "the page must declare it, outside #contest_<id>_games"
  end

  # The rotation drives requestAnimationFrame, and a broadcast detaches the node
  # it animates. Without a teardown the orphaned chain keeps requesting frames
  # forever — measured at one extra 60fps loop per score, 240 -> 480 -> 720 calls
  # per 2s across two touchdowns. The transform version survived the omission by
  # luck: a detached node never fires transitionend, so that chain died by itself.
  test "the carousel tears its animation down when the node goes away" do
    get_live

    # Sliced to the carousel factory, and asserted as a DEFINITION rather than a
    # mention. Half a dozen other components on this page define destroy(), and
    # the factory's own comment names it — so a page-wide substring search stays
    # green with the method deleted. Verified by deleting it: this goes red, the
    # substring version did not.
    factory = games_carousel_source
    assert_match(/destroy\(\)\s*\{/, factory,
      "Alpine's teardown hook must exist, or every score leaks a rAF loop")
    assert_match(/isConnected/, factory,
      "and the loop must self-terminate too, so a missed teardown costs one frame")
  end

  private

  # The strip exactly as the broadcaster re-renders it — same partial, same
  # locals as Contest::LiveBroadcast#replace_games — so what this returns is what
  # a score actually puts on the page.
  # JUST the strip carousel factory, so an assertion about it cannot be satisfied
  # by one of the page's many other Alpine components.
  def games_carousel_source
    body  = response.body
    start = body.index("window.gamesCarousel")
    refute_nil start, "the carousel factory must be on the page at all"
    body[start...body.index("</script>", start)]
  end

  def render_strip_partial
    ApplicationController.render(
      partial: "contests/live_games",
      locals: @contest.games_by_phase.merge(contest: @contest)
    )
  end
end
