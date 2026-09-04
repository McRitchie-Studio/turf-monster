# frozen_string_literal: true

require "test_helper"

# WEEK NUMBERS REPEAT WITHIN A YEAR, and that is the whole reason this file
# exists. NFL preseason week 3 and regular-season week 3 both exist, so a span
# builder that scoped only by week + year + sport answered a preseason request
# with REGULAR-SEASON slates — unplayed games, assembled into a contest, with
# nothing raising. A silent wrong answer, not an error.
class BuildSpanSlateSeasonTest < ActiveSupport::TestCase
  def weekly(name, week:, year: 2026)
    Slate.create!(name: name, week: week, year: year, sport: "nfl")
  end

  setup do
    Slate.where(year: 2027).destroy_all
  end

  # Same year, same sport, same WEEK NUMBERS — differing only in season.
  def build_colliding_weeks
    {
      pre3: weekly("NFL 2027 Preseason Week 3", week: 3, year: 2027),
      pre4: weekly("NFL 2027 Preseason Week 4", week: 4, year: 2027),
      reg3: weekly("NFL 2027 Week 3", week: 3, year: 2027),
      reg4: weekly("NFL 2027 Week 4", week: 4, year: 2027)
    }
  end

  test "season_type is derived from the name, both ways" do
    slates = build_colliding_weeks

    assert_equal Slate::PRESEASON_SEASON_TYPE, slates[:pre3].reload.season_type
    assert_equal Slate::DEFAULT_SEASON_TYPE, slates[:reg3].reload.season_type
  end

  # THE BUG. Without the season scope this returned the regular-season slates
  # and built a contest from games that had not been played.
  test "a preseason span sources PRESEASON weeks, not the regular weeks of the same number" do
    slates = build_colliding_weeks

    builder = Nfl::BuildSpanSlate.new(year: 2027, weeks: [3, 4], season_type: Slate::PRESEASON_SEASON_TYPE)
    sources = builder.send(:source_slates)

    assert_equal [slates[:pre3].id, slates[:pre4].id], sources.map(&:id)
    refute_includes sources.map(&:id), slates[:reg3].id, "a preseason span must not absorb a regular week"
  end

  test "a regular span still sources the regular weeks" do
    slates = build_colliding_weeks

    sources = Nfl::BuildSpanSlate.new(year: 2027, weeks: [3, 4]).send(:source_slates)

    assert_equal [slates[:reg3].id, slates[:reg4].id], sources.map(&:id)
  end

  # A missing preseason week must REFUSE, not fall through to the regular slate
  # that happens to carry the same number. Failing closed is the entire point.
  test "a preseason span refuses when its own week is missing, even if a regular one exists" do
    weekly("NFL 2027 Week 3", week: 3, year: 2027)
    weekly("NFL 2027 Preseason Week 4", week: 4, year: 2027)

    error = assert_raises(Nfl::BuildSpanSlate::Error) do
      Nfl::BuildSpanSlate.new(year: 2027, weeks: [3, 4], season_type: Slate::PRESEASON_SEASON_TYPE).send(:source_slates)
    end

    assert_match(/preseason/i, error.message)
    assert_match(/week 3/, error.message)
  end

  # The two spans must be able to coexist. They are found by name, so the
  # qualifier is load-bearing rather than cosmetic.
  test "a preseason span and a regular span of the same weeks do not collide" do
    pre = Nfl::BuildSpanSlate.slate_name(2027, [3, 4], Slate::PRESEASON_SEASON_TYPE)
    reg = Nfl::BuildSpanSlate.slate_name(2027, [3, 4])

    assert_equal "NFL 2027 Preseason Weeks 3-4", pre
    assert_equal "NFL 2027 Weeks 3-4", reg
    refute_equal pre, reg
  end

  # And the span slate it creates must itself read back as preseason, or a later
  # lookup by season would not find the thing this just built.
  test "the span slate it names round-trips to the right season" do
    assert_equal Slate::PRESEASON_SEASON_TYPE, Slate.season_type_from_name(Nfl::BuildSpanSlate.slate_name(2027, [3, 4], Slate::PRESEASON_SEASON_TYPE))
    assert_equal Slate::DEFAULT_SEASON_TYPE, Slate.season_type_from_name(Nfl::BuildSpanSlate.slate_name(2027, [3, 4]))
  end
end
