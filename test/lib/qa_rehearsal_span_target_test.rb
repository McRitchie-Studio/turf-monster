# frozen_string_literal: true

require "test_helper"

# THE DRIVER NOW TARGETS A SPAN, and both halves of that are load-bearing.
#
# The slate name is not decoration: every step looks the slate up with
# `Slate.find_by!(name: SLATE_NAME)`, so a name the builder does not produce
# fails the rehearsal at step 1 with a bare RecordNotFound. And a span has TWO
# weeks to fetch, which is the half that can go quietly wrong.
class QaRehearsalSpanTargetTest < ActiveSupport::TestCase
  Driver = TurfMonster::QaRehearsal::Driver

  # THE COUPLING. The driver hardcodes a name; the builder composes one. Nothing
  # else checks that they agree, and they are edited in different files by
  # different tasks — so this asserts the driver's constant against the
  # builder's OWN composition rather than against a second hardcoded string.
  test "SLATE_NAME is exactly what BuildSpanSlate names a preseason 3-4 span" do
    composed = Nfl::BuildSpanSlate.slate_name(2026, [3, 4], Slate::PRESEASON_SEASON_TYPE)

    assert_equal composed, Driver::SLATE_NAME,
                 "the driver looks the slate up by this name — if the builder composes " \
                 "a different one, every step fails at find_by!"
  end

  test "the span carries both preseason weeks as poll slots" do
    assert_equal %w[2026:1:3 2026:1:4], Driver::POLL_SLOTS
    assert Driver::POLL_SLOTS.frozen?
    assert_equal 2, Driver::POLL_SLOTS.size, "a span is two weeks — one slot is the old single-week form"
  end

  # THE DANGEROUS HALF. Polling week 4 while week 3 silently failed leaves a
  # half-scored board that still looks plausible — every game of one week final,
  # the other week untouched, which reads as "those games have not kicked off".
  # `conclude` would then grade and settle real money against it.
  test "a failure on ANY slot raises, naming the slot" do
    driver = Driver.new(io: StringIO.new)
    attempted = []
    driver.define_singleton_method(:app) { "turf-monster-qa" }
    # Succeed on the first slot, fail on the second — the ordering that a
    # last-call-wins check would wave through.
    driver.define_singleton_method(:system) do |*args|
      slot = args.last
      attempted << slot
      slot != "2026:1:4"
    end

    error = assert_raises(Driver::StepError) { driver.send(:poll_slots!) }

    assert_equal %w[2026:1:3 2026:1:4], attempted, "every slot must be attempted in order"
    assert_match(/2026:1:4/, error.message, "the operator needs to know WHICH week did not land")
    assert_match(/CLEARED/, error.message, "and that the board is already cleared")
  end

  test "the first slot failing stops before the second is attempted" do
    driver = Driver.new(io: StringIO.new)
    attempted = []
    driver.define_singleton_method(:app) { "turf-monster-qa" }
    driver.define_singleton_method(:system) { |*args| attempted << args.last; false }

    assert_raises(Driver::StepError) { driver.send(:poll_slots!) }

    assert_equal ["2026:1:3"], attempted,
                 "a failed fetch must not be followed by another — the board is already cleared"
  end

  test "every slot landing is a clean pass" do
    driver = Driver.new(io: StringIO.new)
    attempted = []
    driver.define_singleton_method(:app) { "turf-monster-qa" }
    driver.define_singleton_method(:system) { |*args| attempted << args.last; true }

    assert_nothing_raised { driver.send(:poll_slots!) }
    assert_equal %w[2026:1:3 2026:1:4], attempted
  end
end
