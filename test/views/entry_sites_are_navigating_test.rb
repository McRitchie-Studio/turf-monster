# frozen_string_literal: true

require "test_helper"

# EVERY onchainSettled() CALL MUST DECLARE HOW ITS SURFACE LEAVES THE PAGE.
#
# This is a source invariant, and it is deliberately narrow about what it proves:
# it cannot show the settle working, only that no call site has quietly gone back
# to a form that cannot survive the way its own surface exits. The behaviour
# itself is covered by test/lib/onchain_settled_js_test.rb and
# e2e/onchain_settled_navbar.spec.js.
#
# WHY IT EXISTS. The settle seam shipped on the premise that "the entry flow does
# not navigate". It was false and nothing caught it: the engine's success card
# auto-redirects after FIVE seconds (studio/modals/blocks/_success_card:70, armed
# by _entry_confirmed:92, ending in window.location.href), so a ten-second
# non-navigating timer is destroyed at t=5s with no marker written.
#
# The failure mode is invisible: a bare call is valid JavaScript, does something
# plausible, and leaves no trace when the page unloads. So the invariant is
# asserted rather than remembered.
class EntrySitesAreNavigatingTest < ActiveSupport::TestCase
  # Surfaces whose success card redirects on its own countdown. These are GONE
  # by the time the settle window closes, so they may only mark, never schedule.
  REDIRECTING_SURFACES = %w[
    app/views/contests/_turf_totals_board.html.erb
    app/views/contests/new.html.erb
    app/views/contests/generator.html.erb
  ].freeze

  # Surfaces that STAY PUT but may be navigated away from at any moment.
  #
  # WHY SURVIVOR MOVED HERE (survivor-settle-never-fires). It was listed above on
  # the assumption that it auto-redirects like the rest. It does not: it sets no
  # lobbyUrl, so the success card's startCountdown() returns early and no
  # countdown is armed. The card sits there — while modal.onClose assigns
  # window.location, so closing it IS a navigation and is the normal way out.
  # Marking alone left the navbar on the pre-spend figure for as long as the card
  # stayed open; scheduling alone loses the settle the moment the user closes it.
  # These sites take both halves, which is what mayNavigate means.
  STAY_PUT_NAVIGABLE_SURFACES = %w[
    app/views/contests/_world_cup_survivor_board.html.erb
  ].freeze

  ALL_SETTLE_SURFACES = (REDIRECTING_SURFACES + STAY_PUT_NAVIGABLE_SURFACES).freeze

  # A call site as it appears in source: the file, the line, and the shape it
  # declared. Comment lines are prose ABOUT a call, not a call.
  def settle_call_sites(rel)
    path = Rails.root.join(rel)
    assert path.exist?, "#{rel} moved — update these lists rather than deleting the guard"

    path.read.each_line.with_index(1).filter_map do |line, n|
      next unless line.include?("onchainSettled(")
      next if line.strip.start_with?("//")
      { rel: rel, line: n, src: line.strip }
    end
  end

  test "no redirecting surface calls onchainSettled without navigating" do
    offenders = REDIRECTING_SURFACES.flat_map do |rel|
      settle_call_sites(rel).reject { |c| c[:src].include?("navigating: true") }
    end

    assert_empty offenders.map { |c| "#{c[:rel]}:#{c[:line]} — #{c[:src]}" },
      "these sites redirect, so anything but `navigating: true` schedules a timer the unload destroys"
  end

  test "no stay-put navigable surface calls onchainSettled without mayNavigate" do
    offenders = STAY_PUT_NAVIGABLE_SURFACES.flat_map do |rel|
      settle_call_sites(rel).reject { |c| c[:src].include?("mayNavigate: true") }
    end

    assert_empty offenders.map { |c| "#{c[:rel]}:#{c[:line]} — #{c[:src]}" },
      "these sites stay put but navigate on close, so they need BOTH halves: a bare call " \
      "loses the settle when the user closes the card, and `navigating: true` never settles " \
      "the pill for the user who stays"
  end

  # THE CONTROL. Without it the two tests above pass trivially if the calls are
  # all renamed or deleted — they would be asserting the absence of something
  # absent. It pins the SHAPE SPLIT as well as the total, so a site cannot change
  # shape unnoticed in either direction.
  #
  # THE TOTAL DID NOT MOVE, AND THAT IS THE POINT. It was 8 before
  # survivor-settle-never-fires and it is 8 after, because that change added and
  # removed no success path — it re-declared two existing survivor sites from
  # `navigating` to `mayNavigate`. The split below is what moved (8/0 -> 6/2), and
  # it is asserted separately so the re-aim had to name a cause instead of bumping
  # a number until it went green.
  test "the settle surfaces do in fact call onchainSettled, in the shape each needs" do
    navigating = REDIRECTING_SURFACES.to_h do |rel|
      [rel, settle_call_sites(rel).count { |c| c[:src].include?("navigating: true") }]
    end
    may_navigate = STAY_PUT_NAVIGABLE_SURFACES.to_h do |rel|
      [rel, settle_call_sites(rel).count { |c| c[:src].include?("mayNavigate: true") }]
    end

    navigating.merge(may_navigate).each do |rel, n|
      assert_operator n, :>=, 1,
        "#{rel} has no onchainSettled call in its declared shape — either the seam was removed " \
        "or these lists are stale, and both make the tests above vacuous"
    end

    assert_equal 6, navigating.values.sum,
      "expected 6 navigating call sites (4 turf-totals board + create + generator)"
    assert_equal 2, may_navigate.values.sum,
      "expected 2 mayNavigate call sites (the survivor board's on-chain and off-chain branches)"
    assert_equal 8, navigating.values.sum + may_navigate.values.sum,
      "expected 8 on-chain success paths in total — unchanged across survivor-settle-never-fires, " \
      "which moved two of them between shapes rather than adding or losing any. A change in THIS " \
      "number means a success path was added or lost; a change in the split above means a surface " \
      "changed how it exits, and both want a reason, not a new constant"
  end

  # A shape a surface did not declare is a shape it does not handle. Both
  # keywords on one call would be the ambiguity that started this: `navigating`
  # short-circuits and returns null, so it would silently win and the in-page
  # schedule this surface needs would never happen.
  test "no call site declares both shapes at once" do
    both = ALL_SETTLE_SURFACES.flat_map do |rel|
      settle_call_sites(rel).select { |c| c[:src].include?("navigating: true") && c[:src].include?("mayNavigate: true") }
    end

    assert_empty both.map { |c| "#{c[:rel]}:#{c[:line]} — #{c[:src]}" },
      "navigating short-circuits before the schedule, so it silently wins and mayNavigate is a no-op"
  end
end
