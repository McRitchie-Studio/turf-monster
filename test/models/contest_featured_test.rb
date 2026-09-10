# frozen_string_literal: true

require "test_helper"

# WHICH CONTEST "/" LANDS ON.
#
# Contest.featured is the single source of truth for the root redirect
# (ContestsController#world_cup) and the magic-link sign-in landing. It resolves
# down three rungs — the admin's pinned main contest, then the newest OPEN
# contest, then the newest open-or-settled one — and these tests pin what each
# rung is allowed to return.
#
# THE RULE UNDER TEST: the two automatic rungs skip a contest flagged
# `coming_soon`; the admin's pin does not. `coming_soon` is a boolean that is
# independent of status, so a coming-soon contest is `open` and sorts into the
# newest-open query like any other — which is how "/" came to land visitors on
# a contest they could only read about. Filtering it out of the fallbacks fixes
# that; filtering it out of the PIN would instead overrule an admin who chose
# that contest on purpose, so the pin case is asserted separately and in the
# opposite direction.
#
# Each rung is asserted on its own because each one can be fixed alone. A patch
# that filters only the newest-open rung passes the first test here and still
# hands a coming-soon contest to a board with nothing else open, because the
# open-or-settled rung underneath it is a second, independent query.
class ContestFeaturedTest < ActiveSupport::TestCase
  setup do
    # Own the whole resolution chain. The fixtures ship an open contest, which
    # would otherwise sit in every one of these queries. Clear the pointer
    # first so nothing references a row being deleted, then children before
    # parents for the FKs.
    SeasonConfig.set_main_contest!(nil)
    Selection.delete_all
    Entry.delete_all
    Contest.delete_all
  end

  # created_at is the sort key on both fallback rungs, so every contest gets an
  # explicit, well-separated one — leaning on insertion order would let a broken
  # sort pass whenever the rows happened to come back the right way round.
  def contest(slug, created_at:, status: "open", coming_soon: false)
    Contest.create!(
      name: slug.titleize,
      slug: slug,
      status: status,
      coming_soon: coming_soon,
      entry_fee_cents: 1900,
      max_entries: 29,
      contest_type: "standard",
      slate: slates(:one),
      created_at: created_at
    )
  end

  test "the newest open contest wins when nothing is coming soon" do
    older = contest("older-open", created_at: 10.days.ago)
    newer = contest("newer-open", created_at: 1.day.ago)

    assert_equal newer, Contest.featured
    refute_equal older, Contest.featured
  end

  test "a coming soon contest is passed over for an older open one" do
    playable = contest("playable-open", created_at: 30.days.ago)
    contest("fresh-soon", created_at: 1.minute.ago, coming_soon: true)

    # The whole point: newest wins, but only among contests a visitor can act
    # on. A month-old open contest beats a coming-soon one created a minute ago.
    assert_equal playable, Contest.featured
  end

  test "the open-or-settled rung skips coming soon too" do
    # Nothing playable is open, so resolution falls past the newest-open rung.
    # A patch that filters only that rung returns the coming-soon contest here.
    contest("fresh-soon", created_at: 1.minute.ago, coming_soon: true)
    settled = contest("old-settled", created_at: 20.days.ago, status: "settled")

    assert_equal settled, Contest.featured
  end

  test "featured is nil when every contest is coming soon" do
    contest("soon-a", created_at: 2.days.ago, coming_soon: true)
    contest("soon-b", created_at: 1.day.ago, coming_soon: true)

    # nil is the contract world_cup reads to redirect to /contests instead. A
    # coming-soon board has nothing to spotlight, so the index is the landing.
    assert_nil Contest.featured
  end

  test "an admin pinned contest still wins even when it is coming soon" do
    pinned = contest("pinned-soon", created_at: 30.days.ago, coming_soon: true)
    contest("newer-open", created_at: 1.day.ago)
    SeasonConfig.set_main_contest!(pinned)

    # Deliberately the opposite direction from the tests above. An admin
    # choosing a contest at /admin/dashboard is advertising it on purpose, and
    # that outranks the coming-soon rule. Guards against over-correcting the
    # fallbacks into a blanket "never land on coming soon".
    assert_equal pinned, Contest.featured
  end

  test "an open contest still outranks a newer settled one" do
    settled = contest("newer-settled", created_at: 1.day.ago, status: "settled")
    open = contest("older-open", created_at: 10.days.ago)

    # The two fallback rungs are not interchangeable and must not be collapsed
    # into one open-or-settled query: the newest-open rung exists so a live
    # contest beats a finished one that happens to be newer.
    assert_equal open, Contest.featured
    refute_equal settled, Contest.featured
  end
end
