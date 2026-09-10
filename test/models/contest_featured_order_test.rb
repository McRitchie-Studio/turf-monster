# frozen_string_literal: true

require "test_helper"

# WHAT THE FEATURED RAIL SHOWS, AND IN WHAT ORDER.
#
# /contests leads with a horizontal rail of the contests a reader can act on.
# Contest.featured_order owns both halves of that — membership and order — so
# the page and these tests read one definition rather than two that can drift.
#
# The rules it encodes, and the way each one can break:
#
#   TWO BANDS, NOT ONE SORT KEY. Open first, coming-soon after. A naive
#   `sort_by(&:created_at).reverse` gets every same-band case right and puts a
#   coming-soon contest created this morning above an open one created last
#   month — which is the exact case the rail exists to get right, because the
#   reader scanning left to right wants something they can enter.
#
#   NEWEST FIRST WITHIN A BAND. Independently breakable: a tuple with the sign
#   dropped off the date sorts each band oldest-first and still passes every
#   band-order assertion.
#
#   SETTLED AND CANCELLED ARE OUT, and they are NOT the same test. `settled` is
#   a status; `cancelled` is the `onchain_cancelled` boolean and a cancelled
#   contest KEEPS `status: "open"` (Contest#cancelled?). So a filter written
#   against status alone excludes the settled ones, passes a settled-exclusion
#   test, and still floats a dead contest to the top of the page under a red
#   badge. Both are asserted separately for that reason.
class ContestFeaturedOrderTest < ActiveSupport::TestCase
  # created_at is the sort key, so every contest here is given an explicit,
  # well-separated one. Leaning on insertion order would let a broken sort pass
  # by accident whenever the rows happen to come back the right way round.
  def contest(slug, created_at:, status: "open", coming_soon: false, cancelled: false)
    Contest.create!(
      name: slug.titleize,
      slug: slug,
      status: status,
      coming_soon: coming_soon,
      onchain_cancelled: cancelled,
      entry_fee_cents: 1900,
      max_entries: 29,
      contest_type: "standard",
      slate: slates(:one),
      created_at: created_at
    )
  end

  test "open contests come before coming soon ones, however new the coming soon one is" do
    stale_open = contest("stale-open", created_at: 30.days.ago)
    fresh_soon = contest("fresh-soon", created_at: 1.minute.ago, coming_soon: true)

    assert_equal [stale_open, fresh_soon], Contest.featured_order([fresh_soon, stale_open])
  end

  test "each band runs newest to oldest" do
    older_open = contest("older-open", created_at: 10.days.ago)
    newer_open = contest("newer-open", created_at: 2.days.ago)
    older_soon = contest("older-soon", created_at: 9.days.ago, coming_soon: true)
    newer_soon = contest("newer-soon", created_at: 1.day.ago, coming_soon: true)

    assert_equal [newer_open, older_open, newer_soon, older_soon],
                 Contest.featured_order([older_soon, older_open, newer_soon, newer_open])
  end

  test "a settled contest is not on the rail" do
    open_one = contest("still-open", created_at: 5.days.ago)
    settled  = contest("all-done", created_at: 1.day.ago, status: "settled")

    assert_equal [open_one], Contest.featured_order([settled, open_one])
  end

  # The distinct half of the exclusion: this contest's STATUS is still "open".
  # A membership filter that only asks about status keeps it.
  test "a cancelled contest is not on the rail even though its status is still open" do
    open_one  = contest("live-one", created_at: 5.days.ago)
    cancelled = contest("called-off", created_at: 1.day.ago, cancelled: true)

    assert_equal "open", cancelled.status
    assert_equal [open_one], Contest.featured_order([cancelled, open_one])
  end

  test "a cancelled coming soon contest is dropped rather than sorted to the back" do
    cancelled_soon = contest("soon-but-dead", created_at: 1.day.ago, coming_soon: true, cancelled: true)

    assert_empty Contest.featured_order([cancelled_soon])
  end
end
