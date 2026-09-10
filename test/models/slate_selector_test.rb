require "test_helper"

# The slate selector row: compact labels, and a multi-week span sitting next to
# the week it starts on rather than wherever creation date left it.
class SlateSelectorTest < ActiveSupport::TestCase
  setup do
    # Ordering assertions need an empty slate table, and slates are referenced by
    # contests (and transitively by entries/selections) — clear dependents first
    # or the delete trips a foreign key.
    Selection.delete_all
    SurvivorPick.delete_all
    Message.delete_all
    Entry.delete_all
    Contest.delete_all
    SlateMatchup.delete_all
    NflTeamTotalProjection.delete_all
    Slate.delete_all
  end

  def slate!(name)
    Slate.create!(name: name, slug: name.parameterize)
  end

  # --- week parsing -------------------------------------------------------

  test "week_range reads a single week" do
    assert_equal 7..7, slate!("NFL 2026 Week 7").week_range
  end

  test "week_range reads a span" do
    assert_equal 1..3, slate!("NFL 2026 Weeks 1-3").week_range
  end

  test "week_range handles an en dash" do
    assert_equal 5..7, slate!("NFL 2026 Weeks 5–7").week_range
  end

  test "week_range is nil for slates with no week" do
    assert_nil slate!("World Cup 2026 Round of 32").week_range
    # "Group 1" must NOT parse as week 1 — it would sort among the NFL weeks.
    assert_nil slate!("World Cup 2026 Group 1").week_range
  end

  # --- labels -------------------------------------------------------------

  test "selector_label drops the competition and year prefix" do
    assert_equal "Week 1", slate!("NFL 2026 Week 1").selector_label
    assert_equal "Weeks 1-3", slate!("NFL 2026 Weeks 1-3").selector_label
    assert_equal "Round of 32", slate!("World Cup 2026 Round of 32").selector_label
    # Previously rendered as a bare "1", which read as a week number.
    assert_equal "Group 1", slate!("World Cup 2026 Group 1").selector_label
  end

  test "selector_label leaves an unrecognised name alone" do
    assert_equal "Custom Slate", slate!("Custom Slate").selector_label
  end

  # --- sport marker -------------------------------------------------------

  test "NFL slates are football, World Cup slates are soccer" do
    assert_equal "🏈", slate!("NFL 2026 Week 1").sport_emoji
    assert_equal "⚽", slate!("World Cup 2026 Round of 32").sport_emoji
    assert_equal "⚽", slate!("World Cup 2026 Group 1").sport_emoji
  end

  test "a span slate is football even though it says Weeks, not Week" do
    # `week\s+\d` (singular) misses "Weeks 1-3"; it only classified today by
    # also matching the "NFL" token, so a span named without it would fall to
    # soccer.
    assert_equal "🏈", slate!("Weeks 1-3").sport_emoji
    assert_equal "nfl", slate!("NFL 2026 Weeks 5-7").sport
  end

  test "an unrecognised slate falls back to soccer" do
    assert_equal "⚽", slate!("Custom Slate").sport_emoji
  end

  # --- ordering -----------------------------------------------------------

  test "a span sits immediately after the week it starts on" do
    # Created LAST, as it would be in practice — creation order is what used to
    # strand it at the end of the row.
    slate!("NFL 2026 Week 1")
    slate!("NFL 2026 Week 2")
    slate!("NFL 2026 Week 3")
    slate!("NFL 2026 Weeks 1-3")

    assert_equal ["Week 1", "Weeks 1-3", "Week 2", "Week 3"],
                 Slate.selector_ordered.map(&:selector_label)
  end

  test "NFL weeks sort numerically, not as strings" do
    slate!("NFL 2026 Week 10")
    slate!("NFL 2026 Week 2")

    assert_equal ["Week 2", "Week 10"], Slate.selector_ordered.map(&:selector_label)
  end

  test "weekless slates keep creation order and lead the row" do
    # Creation order is tournament order; sorting these by name would put the
    # Final first.
    slate!("World Cup 2026 Round of 32")
    slate!("World Cup 2026 Final")
    slate!("NFL 2026 Week 1")

    assert_equal ["Round of 32", "Final", "Week 1"],
                 Slate.selector_ordered.map(&:selector_label)
  end

  test "the Default formula holder is excluded" do
    slate!("Default")
    slate!("NFL 2026 Week 1")

    assert_equal ["Week 1"], Slate.selector_ordered.map(&:selector_label)
  end
end
