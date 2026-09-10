require "test_helper"

# [component] The contest show page's four header rows, as an operator mockup
# defined them for mobile (task: mobile-contest-header-rows).
#
# The layout it pins:
#   Row 1  the contest name, one type step larger than it was
#   Row 2  an INSET panel carrying prizes / entry / entries, and nothing else
#   Row 3  a new label-over-value meta grid — creator, start countdown, league
#          span — which absorbed BOTH the old "week span · creator" subtitle
#          above the title AND the start countdown that used to ride inside
#          Row 2
#   Row 4  the multi-week board's left label, now just "Pick N teams"
#
# Every assertion here is about something that MOVED. The row that gains an
# element and the row that loses it are asserted as a pair, because a partial
# that renders the countdown in both places satisfies a one-sided test.
class ContestHeaderRowsTest < ActionDispatch::IntegrationTest
  # The rows are addressed by their `data-contest-row` hook, NOT by their
  # utility classes: `.bg-inset` and `.grid-cols-3` each appear ~10 and 3 times
  # on a rendered contest page, so a class-based selector silently matches the
  # quest card and the leaderboard too — which is how the first draft of this
  # test passed a "count: 1" assertion against 10 elements.
  TITLE_ROW = "[data-contest-row=title]"
  STATS_ROW = "[data-contest-row=stats]"
  META_ROW  = "[data-contest-row=meta]"

  setup do
    @contest = contests(:one)
  end

  # --- Row 1 ------------------------------------------------------------

  test "[component] the contest name leads at the larger mobile size" do
    get contest_path(@contest)

    assert_response :success
    # text-2xl was the old mobile size. The header is the card's title on a
    # 390px screen and was reading at the same weight as the stats beneath it.
    assert_select "h1.text-3xl", text: /#{@contest.name}/
    assert_select "h1.text-2xl", count: 0,
      message: "Row 1 must not fall back to the pre-mockup mobile size"
  end

  # --- Row 2 ------------------------------------------------------------

  test "[component] the money row holds exactly the three figures" do
    get contest_path(@contest)

    assert_response :success
    assert_select STATS_ROW, count: 1
    assert_select "#{STATS_ROW} > div", count: 3,
      message: "Row 2 carries prizes, entry and entries — nothing else moved back in"
    %w[Prizes Entry Entries].each do |label|
      assert_select "#{STATS_ROW} span.text-muted", text: label
    end
  end

  # Rows 2 and 3 are ONE block with two layouts, and both halves are asserted
  # because each can break without the other. An earlier cut gave Row 2 its own
  # inset panel and its own flex spacing; the operator's corrections were that
  # it carries no surface, that it shares Row 3's columns on mobile, and that
  # from md the two sit on one line with Row 3 to the RIGHT of Row 2.
  test "[component] the money row carries no surface" do
    get contest_path(@contest)

    assert_response :success
    assert_select "#{STATS_ROW}.bg-inset", count: 0,
      message: "Row 2 has no background of its own — type size carries the hierarchy"
  end

  test "[component] the two rows share one set of tracks and pair up at md" do
    get contest_path(@contest)

    assert_response :success
    stats = css_select(STATS_ROW).first
    meta  = css_select(META_ROW).first

    wrapper = stats.parent
    assert_equal meta.parent, wrapper,
                 "Rows 2 and 3 must share a parent for either layout to apply"

    # MOBILE — the two wrappers go display:contents, so their six cells become
    # direct items of the wrapper grid and BOTH rows resolve against one set of
    # tracks. That is the whole mechanism behind the columns lining up; a
    # per-row `grid-cols-3` cannot do it, because equal thirds are 111px at
    # 390px and the creator cell needs 122.
    assert_includes stats["class"], "contents"
    assert_includes meta["class"], "contents"
    assert_includes wrapper["class"], "grid"
    assert_includes wrapper["class"], "grid-cols-[auto_auto_1fr]",
                    "content-sized tracks are what stop the creator name clipping"
    refute_includes wrapper["class"], "grid-cols-3",
                    "equal thirds clip the widest cell — that is the bug this replaced"

    # md and up — both wrappers become flex containers again, laid out
    # left-to-right by the wrapper, each hugging its own content.
    assert_includes stats["class"], "md:flex"
    assert_includes meta["class"], "md:flex"
    assert_includes wrapper["class"], "md:flex"
    assert_includes wrapper["class"], "md:items-baseline",
                    "paired up, Row 3 sits on Row 2's baseline rather than its box centre"

    kids = wrapper.element_children
    assert_operator kids.index(stats), :<, kids.index(meta),
                    "Row 3 sits to the RIGHT of Row 2, so it must follow it in the DOM"

    # Measured: with items-center the six muted labels landed on four different
    # axes. Baseline on BOTH row containers AND the wrapper is what puts
    # "Prizes", "Entry", "Entries", "NFL", "Starts in" and "creator" on one line.
    [stats, meta].each do |row|
      assert_includes row["class"], "md:items-baseline",
                      "the muted labels must share an axis across both rows"
      refute_includes row["class"], "md:items-center"
    end
  end

  # --- Row 3 ------------------------------------------------------------

  test "[component] each meta cell reads value then label on one line" do
    get contest_path(@contest)

    assert_response :success
    assert_select "#{META_ROW} span.text-muted", text: "creator"
    assert_select "#{META_ROW} span.text-heading", text: @contest.slate.name

    # The league is the LABEL and the span is the VALUE, per the mockup's
    # "NFL" beside "Weeks 1 - 3". `one` is a non-NFL fixture slate.
    assert_select "#{META_ROW} span.text-muted", text: "World Cup"

    # Inline at EVERY width, on a shared baseline so the 10px label sits on the
    # 12px value's baseline rather than its box.
    cell = css_select("#{META_ROW} > div").first
    assert_includes cell["class"], "items-baseline"
    refute_match(/flex-col/, cell["class"],
                 "the operator asked for label and value on one line, mobile included")

    # Same grammar as Row 2's "$500 Prizes": bold value first, muted label after.
    order = cell.element_children.map { |c| c["class"] }
    assert_match(/text-heading/, order.first, "the bold value leads, as it does in Row 2")
    assert_match(/text-muted/, order.last, "the muted label trails it")

    # Row 3 sits TWO type steps below Row 2's text-lg figures — these are the
    # reference details, not the numbers a player decides on.
    assert_select "#{META_ROW} span.text-xs.font-bold", minimum: 2
    assert_select "#{META_ROW} span.text-sm", count: 0,
      message: "Row 3 must not climb back to the Row 2-adjacent size"
  end

  # The operator's order, left to right: the slate span, the countdown, then
  # the creator. Asserted on the rendered cells rather than the source, since
  # two of the three are conditional and could be reordered by an `if`.
  test "[component] Row 3 runs slate, countdown, creator" do
    contest = multi_week_contest

    get contest_path(contest)

    assert_response :success
    cells = css_select("#{META_ROW} > div")
    assert_equal 3, cells.size

    assert_match(/Weeks 1-3/, cells[0].text, "the slate span leads Row 3")
    assert_match(/NFL/,       cells[0].text)
    assert_match(/Starts in/, cells[1].text, "the countdown sits in the middle")
    assert_match(/creator/,   cells[2].text, "the creator trails")
  end

  test "[component] the countdown cell takes the same shape as its neighbours" do
    get contest_path(@contest)

    assert_response :success
    plain     = css_select("#{META_ROW} > div").first["class"]
    countdown = css_select("#{META_ROW} [x-show=\"!done\"]").first

    refute_nil countdown, "the running countdown must render inside Row 3"
    assert_equal plain, countdown["class"],
      "the countdown must take the plain cells' exact shape via shell_class — " \
      "any divergence and its label drifts off the row's baseline"
  end

  # What keeps the pair on ONE line at tablet width. Measured at 768px: the
  # wrapper has 736px, Row 2 takes 302 and the gap 32, leaving 402 for Row 3 —
  # and with all four units showing, Row 3 wants 415 and wraps to a second line.
  # Two units drop its countdown cell to ~100px and the row fits.
  #
  # Asserted on the RENDERED x-show expressions, because WHICH two units show
  # has to slide as the clock rolls over (d+h while days remain, h+m inside a
  # day, m+s inside an hour) — a guard that only counted units at render time
  # would pass a timer that shows four the moment it drops under a day.
  test "[component] Row 3's countdown shows only its two leading units" do
    get contest_path(@contest)

    assert_response :success
    meta  = css_select(META_ROW).first
    shows = meta.css("span").filter_map { |n| n["x-show"] }

    %w[d\ >\ 0 d\ >\ 0\ ||\ h\ >\ 0 d\ ===\ 0 d\ ===\ 0\ &&\ h\ ===\ 0].each do |guard|
      assert_includes shows, guard.tr("\\", "").gsub("\\ ", " "),
        "the two-unit window needs this guard to slide as the clock rolls over"
    end

    # The four-unit path binds m/s visibility to a breakpoint class instead.
    # Both mechanisms live in the partial; only one may reach Row 3.
    binds = meta.css("span").filter_map { |n| n[":class"] }
    assert_empty binds.select { |b| b.include?("sm:inline-flex") },
      "Row 3 must not fall back to the four-unit responsive path"
  end

  test "[component] the start countdown left Row 2 for Row 3" do
    get contest_path(@contest)

    assert_response :success
    assert @contest.starts_in_at.present?, "fixture must have a start time for this to mean anything"

    assert_select "#{META_ROW} span", text: "Starts in",
      message: "the countdown's label belongs to the meta grid now"
    assert_select "#{STATS_ROW} span", text: /Starts/i, count: 0,
      message: "it must LEAVE Row 2, not be rendered in both places"
  end

  test "[component] the old week-span-and-creator subtitle above the title is gone" do
    get contest_path(@contest)

    assert_response :success
    # The subtitle was the only `&middot;` separator in the header block, and
    # its creator name is now a Row 3 value rather than a bare inline span.
    title_row = css_select(TITLE_ROW).first
    refute_nil title_row
    refute_match(/·/, title_row.parent.to_html,
                 "the middot subtitle was consolidated into the Row 3 meta grid")
  end

  # --- Row 4 ------------------------------------------------------------

  # Built rather than fixtured: the mockup is a multi-week contest, and the
  # left label only exists on that branch of the board (a single-week board
  # renders the Sort toggle there, which is functional UI and stays).
  test "[component] the multi-week board label reads just Pick N teams" do
    contest = multi_week_contest

    get contest_path(contest)

    assert_response :success
    assert contest.multi_week?, "this guard is about the multi-week branch"

    label = css_select("section span.text-muted").map(&:text).map(&:strip)
             .find { |t| t.start_with?("Pick ") }
    refute_nil label, "the multi-week board must still say how many teams to pick"
    assert_equal "Pick #{contest.picks_required} teams", label

    refute_includes label, contest.week_span_label,
      "the week span moved to Row 3 — repeating it here crowded the filter input"
  end

  test "[component] the week span still reaches the reader, from Row 3" do
    contest = multi_week_contest

    get contest_path(contest)

    assert_response :success
    # The span is the whole point of a multi-week contest. Deleting it from
    # Row 4 is only safe because Row 3 carries it.
    assert_select "#{META_ROW} span.text-heading", text: contest.week_span_label
    assert_select "#{META_ROW} span.text-muted", text: "NFL"
  end

  private

  # A three-week NFL span contest — the shape the operator's mockup drew.
  def multi_week_contest
    slates = (1..3).map do |week|
      Slate.create!(name: "NFL 2026 Week #{week}", slug: "nfl-2026-wk#{week}-hdr", week: week, year: 2026)
    end
    span = Slate.create!(name: "NFL 2026 Weeks 1-3", slug: "nfl-2026-weeks-1-3-hdr", week: 1, year: 2026)

    %w[team-a team-b team-c team-d team-e team-f].each_with_index do |team, index|
      slates.each_with_index do |_slate, offset|
        SlateMatchup.create!(slate: span, team_slug: team,
                             opponent_team_slug: "team-#{('a'.ord + ((index + 1) % 6)).chr}",
                             game_slug: "#{team}-hdr-wk#{offset + 1}",
                             week: offset + 1, rank: index + 1, turf_score: 1.0 + index,
                             expected_score: 25.0 - index, status: "pending")
      end
    end

    Contest.create!(name: "Span Contest", slug: "span-contest-hdr", slate: span,
                    entry_fee_cents: 1900, status: :open, max_entries: 29,
                    contest_type: :standard, starts_at: 30.days.from_now, user: users(:alex))
  end
end
