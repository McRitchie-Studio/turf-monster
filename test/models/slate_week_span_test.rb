require "test_helper"

# `slates.week` makes the NFL week a sortable fact instead of a substring of the
# slate name, so a multi-week contest can prove its span is consecutive.
class SlateWeekSpanTest < ActiveSupport::TestCase
  setup do
    @w1 = Slate.create!(name: "NFL 2026 Week 1", slug: "nfl-2026-week-1", week: 1)
    @w2 = Slate.create!(name: "NFL 2026 Week 2", slug: "nfl-2026-week-2", week: 2)
    @w3 = Slate.create!(name: "NFL 2026 Week 3", slug: "nfl-2026-week-3", week: 3)
  end

  test "consecutive_weeks returns the span in week order" do
    assert_equal [@w1, @w2, @w3], @w1.consecutive_weeks(3)
  end

  test "consecutive_weeks of one is just the anchor" do
    assert_equal [@w1], @w1.consecutive_weeks(1)
  end

  test "consecutive_weeks starts from the anchor, not the season" do
    assert_equal [@w2, @w3], @w2.consecutive_weeks(2)
  end

  test "consecutive_weeks stops at a gap rather than skipping a week" do
    @w2.destroy!

    # Weeks 1 and 3 exist but are NOT consecutive. Returning [w1, w3] would
    # silently sell a "Week 1-3" contest that skips week 2.
    assert_equal [@w1], @w1.consecutive_weeks(3)
  end

  test "consecutive_weeks stops at the end of the season" do
    assert_equal [@w2, @w3], @w2.consecutive_weeks(5)
  end

  test "consecutive_weeks stays within the anchor's season" do
    # Week numbers recur every year. A prior-season slate shares week 2's number
    # but belongs to a different contest — pulling it into a 2026 span would
    # price and settle wrong-season matchups on a money app.
    prior = Slate.create!(name: "NFL 2025 Week 2", slug: "nfl-2025-week-2", week: 2)

    span = @w1.consecutive_weeks(3)

    # Same-season happy path: exactly the three 2026 slates, in week order.
    assert_equal [@w1, @w2, @w3], span
    assert_not_includes span, prior, "a 2026 span must not absorb a 2025 slate"
  end

  test "consecutive_weeks scopes a year-less slate to other year-less slates" do
    # A name with no year scopes to other year-less slates rather than silently
    # cross-matching a dated one that happens to share the week number.
    a = Slate.create!(name: "Preseason Week 1", slug: "preseason-week-1", week: 1)
    Slate.create!(name: "Preseason Week 2", slug: "preseason-week-2", week: 2)

    assert_equal ["Preseason Week 1", "Preseason Week 2"], a.consecutive_weeks(2).map(&:name)
  end

  test "a slate with no week number cannot span" do
    assert_equal [slates(:one)], slates(:one).consecutive_weeks(3)
  end

  test "weekly excludes the Default formula holder and weekless slates" do
    Slate.create!(name: "Default", slug: "default-slate")

    assert_equal [@w1, @w2, @w3], Slate.weekly.to_a
  end

  test "the ingest service records the week as data" do
    slate = Slate.find_or_initialize_by(name: "NFL 2026 Week 7")
    slate.week = 7
    slate.save!

    assert_equal 7, slate.reload.week
  end

  # --- span labelling -----------------------------------------------------

  test "week_span_label reads Weeks 1-3 off a span slate" do
    span = Slate.create!(name: "NFL 2026 Weeks 1-3", slug: "nfl-2026-weeks-1-3", week: 1)
    contest = contests(:one)
    contest.update!(slate: span)

    assert_equal "Weeks 1-3", contest.week_span_label
  end

  test "week_span_label reads a single week for a one week contest" do
    contest = contests(:one)
    contest.update!(slate: @w2)

    assert_equal "Week 2", contest.week_span_label
  end

  test "week_span_label is nil when the slate has no week number" do
    assert_nil contests(:one).week_span_label
  end
end
