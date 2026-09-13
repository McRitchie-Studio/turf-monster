require "test_helper"

# [component] THE FOCUS RAIL'S TOP HALF — what the hero tile says about where a
# game is up to, and what it has stopped saying.
#
# THE COMPLAINT THESE ANSWER. The rail spent its three lines on the KICKOFF for
# every game, live or not, and then repeated ESPN's own restatement of it
# underneath: a scheduled game printed "SEP 10", "Thu 6:35 PM" and "9/10 - 8:35
# PM EDT" — the same fact three times, the third of them in a zone that is not
# the reader's. A game being played printed the date it started, which nobody
# watching it needs, and said nothing about the down.
#
# So the rail now asks what STATE the game is in and spends the lines
# accordingly: the clock, the down and the possession while it is being played;
# the date and the kickoff before it is.
class LiveFocusSituationRenderTest < ActionDispatch::IntegrationTest
  setup do
    Team.where(slug: %w[team-a team-b team-c team-d]).update_all(league: "nfl", sport: "football")

    @live = Game.create!(home_team_slug: "team-a", away_team_slug: "team-b",
                         season_year: 2026, season_type: 2, week: 4,
                         status: "in_progress", status_detail: "6:06 - 3rd",
                         period: 3, clock: "6:06",
                         down_distance: "3rd & 9",
                         possession_text: "TMB 13", possession_team_slug: "team-b",
                         kickoff_at: 1.hour.ago)
    @scheduled = Game.create!(home_team_slug: "team-c", away_team_slug: "team-d",
                              season_year: 2026, season_type: 2, week: 4,
                              status: "scheduled", status_detail: "9/10 - 8:35 PM EDT",
                              kickoff_at: 3.hours.from_now)
  end

  # A goal is what brings the events frame into being — the rail renders none
  # for a game with no scores, so the seam has nothing to move for.
  def score!(game)
    game.update_column(:slug, game.name_slug) if game.slug != game.name_slug
    game.reload.goals.create!(team_slug: "team-a", points: 3, scoring_type: "field_goal",
                              scorer_name: "Sam Kicker")
  end

  def rail_for(slug)
    css_select("[data-focus-slug='#{slug}'] [data-test='live-focus-status']").first
  end

  def line(slug, role)
    rail_for(slug)&.css("[data-test='live-focus-#{role}']")&.first&.text&.strip
  end

  test "a live game spends the rail on the clock, the down and the possession" do
    get live_path

    assert_response :success
    assert_equal "Q3 · 6:06", line(@live.slug, "clock")
    assert_equal "3rd & 9", line(@live.slug, "down")
    assert_equal "TMB on TMB 13", line(@live.slug, "possession")
  end

  # THE KICKOFF IS GONE FROM A LIVE GAME'S RAIL. The date a game started is not
  # what a reader watching it wants those two lines for, and it was crowding out
  # the two facts that change every snap.
  test "a live game's rail no longer prints its kickoff" do
    get live_path

    rail = rail_for(@live.slug)
    assert_empty rail.css("time[data-role='kickoff']"),
      "a live game's rail is about the play clock, not the kickoff clock"
    assert_empty rail.css("time[data-role='kickoff-date']")
  end

  # ── THE ORIGINAL COMPLAINT ────────────────────────────────────────────────
  #
  # "when not live drop the 9/10 as the date is on the top". ESPN's shortDetail
  # for a scheduled game IS the date and kickoff, restated in whatever zone the
  # feed chose — and the two lines above it already say the same thing in the
  # READER's zone, written by the browser. Printing it was the same fact twice
  # and the second copy was the wrong one.
  test "a scheduled game's rail drops ESPN's restatement of the kickoff" do
    get live_path

    rail = rail_for(@scheduled.slug)
    assert_not_includes rail.text, "9/10",
      "the feed's own kickoff restatement must not appear under the kickoff"
    assert_not_includes rail.text, "EDT"
  end

  test "a scheduled game keeps the date and the kickoff the browser rewrites" do
    get live_path

    rail = rail_for(@scheduled.slug)
    assert_equal 1, rail.css("time[data-role='kickoff-date']").size
    assert_equal 1, rail.css("time[data-role='kickoff']").size
    assert_empty rail.css("[data-test='live-focus-down']"),
      "a game nobody is playing has no down"
  end

  # BETWEEN POSSESSIONS AND AT THE HALF there is no situation at all — ESPN
  # simply drops the block. The big line falls back to the detail, but ONLY when
  # the detail is not the clock printed above it: "Halftime" says something new,
  # "6:06 - 3rd" is the loudest line on the card repeating the quietest.
  test "a live game with no down falls back to a detail that adds something" do
    @live.update!(down_distance: nil, status_detail: "Halftime", clock: "0:00", period: 2)
    get live_path

    assert_equal "Halftime", line(@live.slug, "down")
  end

  test "a live game with no down does not restate its own clock in the big line" do
    @live.update!(down_distance: nil)
    get live_path

    assert_nil line(@live.slug, "down"),
      "'6:06 - 3rd' is the clock line again — the rail leaves the slot empty rather than echo it"
    assert_equal "Q3 · 6:06", line(@live.slug, "clock")
  end

  # ── THE WHEEL ─────────────────────────────────────────────────────────────
  #
  # The top half is a two-pane track, and every slot the page writes into has to
  # exist before it can be written: a missing one throws inside paintStatusEvent
  # and takes the announcement down with it.
  test "the rail's top half ships as a wheel with both panes" do
    get live_path

    rail = rail_for(@live.slug)
    assert_equal 1, rail.css(".tt-status-track").size
    assert_equal 1, rail.css("[data-role='status-game']").size
    assert_equal 1, rail.css("[data-role='status-event']").size
  end

  test "every slot the announcement writes into is present and empty" do
    get live_path

    pane = rail_for(@live.slug).css("[data-role='status-event']").first
    %w[location headline detail name].each do |role|
      slot = pane.css("[data-role='status-#{role}']").first
      assert slot, "paintStatusEvent writes into [data-role=status-#{role}]"
      assert_equal "", slot.text.strip,
        "the pane ships empty — a server-rendered scorer would flash on every unrelated goal"
    end
  end

  # THE TWO HALVES DIVIDE THE ANNOUNCEMENT, they do not duplicate it.
  #
  # The first cut gave the portrait pane its own copy of the city, the action,
  # the play and the player — the same four lines this half shows, in a second
  # size, eight inches apart. The operator's verdict was one copy: the words
  # here, where there is room for them at a readable size, and the face below,
  # where it can have the whole pane.
  test "the portrait pane carries no words of its own" do
    get live_path

    %w[scorer-headline scorer-name scorer-detail scorer-location scorer-mascot].each do |gone|
      assert_select "[data-role=scorer-card] [data-role=#{gone}]", { count: 0 },
        "[data-role=#{gone}] belongs to the status half — a copy here is the duplicate"
    end
  end

  # ── THE WORDS KEEP THEIR HALF; THE FRAME REACHES UP ───────────────────────
  #
  # The first cut of the overlap moved the SEAM — 38/62 — which bought the
  # portrait its room by taking it from the words, and the four lines re-centred
  # in a shorter box. The operator's verdict was that their centring was right
  # as it was. So the status block keeps h-1/2 and the frame below reaches up
  # past it instead, by a fixed 1.25rem.
  #
  # PINNED AS A PAIR. The height and the negative margin have to agree or the
  # rail's floor stops being the card's edge: half plus the overlap, started an
  # overlap early, lands the bottom back on H whatever H is. Nothing else in the
  # suite would notice them drifting apart, and the e2e spec that measures the
  # RESULT (flush at the bottom, crossing the divider at the top) runs in a lane
  # this one does not.
  test "the status block keeps the rows' seam for its words" do
    score!(@live)
    get live_path

    status = css_select("[data-focus-slug='#{@live.slug}'] [data-role='status-frame']").first
    assert_includes status["class"].split, "h-1/2",
      "the words centre in the same box they always did"
  end

  test "the portrait's frame reaches above the seam and still ends on the floor" do
    score!(@live)
    get live_path

    frame = css_select("[data-focus-slug='#{@live.slug}'] [data-role='event-feed-frame']").first
    classes = frame["class"].split

    assert_includes classes, "-mt-5", "the frame starts 1.25rem above the seam"
    assert_includes classes, "h-[calc(50%+1.25rem)]",
      "and is that much taller, so its floor is still the card's edge"
  end

  # ONLY THE PORTRAIT GETS THE OVERLAP.
  #
  # The frame reaches above the rows' seam so the head can cross it — and the
  # events list rides that same frame, so without paying the reach back the LIST
  # crossed it too and hung "Field Goal +3" over the clock. A picture breaking a
  # boundary reads as depth; a list doing it reads as a layout fault.
  #
  # Padding on the pane, not a shorter pane: the panes are thirds of a 300%
  # track and the wheel's arithmetic depends on them staying equal.
  test "the events list pays back the frame's reach so only the portrait bleeds" do
    score!(@live)
    get live_path

    frame = css_select("[data-focus-slug='#{@live.slug}'] [data-role='event-feed-frame']").first
    list  = frame.css("[data-test='live-focus-events']").first.parent

    assert_includes list["class"].split, "pt-5",
      "the list starts at the seam, not at the top of a frame that reaches past it"
    assert_includes frame.css(".tt-fade-top").first["class"].split, "top-5",
      "and its fade follows it — the fade marks the top of the LIST"
  end

  # The event pane is hidden from assistive tech until the page fills it in.
  # It is on screen only after a roll, and a screen reader announcing a blank
  # four-line block on every tile is noise on sixteen games at once.
  test "the announcement pane ships hidden from assistive technology" do
    get live_path

    pane = rail_for(@live.slug).css("[data-role='status-event']").first
    assert_equal "true", pane["aria-hidden"]
  end
end
