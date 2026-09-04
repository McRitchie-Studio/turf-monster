# frozen_string_literal: true

require "test_helper"

# WHAT THE LIVE BOARD CALLS ITSELF.
#
# The page renders in every contest state now — a link an operator has should
# work — but its header announced "Live", with a pulsing red dot, unconditionally.
# So a contest that had not kicked off and one that had already paid out both
# claimed to be in progress. The badge is the first thing read on that page.
#
# The label names the contest's STATE to a human, in a fixed precedence:
# cancelled, then final, then live, then upcoming. Cancellation is a boolean
# orthogonal to `status`, so it can be true alongside any of the other three;
# it wins outright because a refunded contest is over no matter what else is
# true of it.
#
# These tests assert on what the PAGE renders, not on what the helper returns.
# A helper can return the right symbol into a view that ignores it, and the
# label and the pulse are two independently breakable halves — so every case
# below pins the label text, the state attribute, AND the presence or absence
# of the pulse.
class ContestLiveStateTest < ActionDispatch::IntegrationTest
  include ContestsHelper

  setup { @contest = contests(:one) }

  test "a contest that has not locked reads as not started" do
    @contest.update!(starts_at: 1.hour.from_now, status: "open")

    get live_contest_path(@contest)

    assert_response :success
    assert_select "[data-test='live-state'][data-state='upcoming']"
    assert_select "[data-test='live-state']", text: /Not started/i
    assert_select "[data-test='live-state'] .animate-pulse", { count: 0 },
                  "a contest that has not kicked off must not pulse like one that has"
  end

  test "a locked, unsettled contest reads as live and pulses" do
    @contest.update!(starts_at: 1.hour.ago, status: "open")
    assert @contest.reload.live?, "fixture must be live for this test to mean anything"

    get live_contest_path(@contest)

    assert_select "[data-test='live-state'][data-state='live']"
    assert_select "[data-test='live-state']", text: /Live/i
    assert_select "[data-test='live-state'] .animate-pulse"
  end

  test "a settled contest reads as final, not live" do
    @contest.update!(starts_at: 1.hour.ago, status: "settled")

    get live_contest_path(@contest)

    assert_select "[data-test='live-state'][data-state='final']"
    assert_select "[data-test='live-state']", text: /Final/i
    assert_select "[data-test='live-state'] .animate-pulse", count: 0
  end

  # The tab title is the same claim in a smaller place — a settled contest
  # sitting in a browser tab labelled "Live" is still wrong.
  test "the tab title carries the state too" do
    @contest.update!(starts_at: 1.hour.ago, status: "settled")

    get live_contest_path(@contest)

    assert_select "title", text: /Final/
  end

  # PRECEDENCE, END TO END. A contest can be cancelled while locked and unsettled
  # — cancel-while-locked is deliberately supported (contests/show gates the
  # entry board on `open? && !cancelled?`, not on `!locked?`) — and `live?` is
  # `locked? && !settled?`, so `live?` is TRUE for such a contest. It read "Live",
  # pulsing, on a terminal refunded contest.
  #
  # The badge no longer tracks `live?`. It is not a claim about whether a packet
  # can arrive; it is a claim about what the contest IS.
  test "a cancelled contest that has locked reads as cancelled, not live" do
    @contest.update!(starts_at: 1.hour.ago, status: "open", onchain_cancelled: true)
    assert @contest.reload.live?,
           "the bug needs live? to be TRUE here — without that this test proves nothing"

    get live_contest_path(@contest)

    assert_response :success
    assert_select "[data-test='live-state'][data-state='cancelled']"
    assert_select "[data-test='live-state']", text: /Cancelled/i
    assert_select "[data-test='live-state']", { text: /Live/i, count: 0 },
                  "a refunded contest must not announce itself as in progress"
    assert_select "[data-test='live-state'] .animate-pulse", { count: 0 },
                  "a terminal contest must not pulse like one that is in progress"
  end

  test "a cancelled contest that has not locked reads as cancelled, not not-started" do
    @contest.update!(starts_at: 1.hour.from_now, status: "open", onchain_cancelled: true)
    refute @contest.reload.live?

    get live_contest_path(@contest)

    assert_select "[data-test='live-state'][data-state='cancelled']"
    assert_select "[data-test='live-state']", text: /Cancelled/i
    assert_select "[data-test='live-state']", { text: /Not started/i, count: 0 },
                  "a cancelled contest is over, not waiting to begin"
    assert_select "[data-test='live-state'] .animate-pulse", count: 0
  end

  # THE ORDERING RULE. Both terminal flags can be set at once — a contest can be
  # settled and then cancelled on-chain: grade! carries no cancelled guard, and
  # the 2-of-3 cosign that finally writes onchain_cancelled re-checks nothing.
  # Cancelled wins. Not because the money went back — it may not have — but
  # because it is the state that tells the viewer to stop waiting on a result.
  test "cancelled wins over settled when both apply" do
    @contest.update!(starts_at: 1.hour.ago, status: "settled", onchain_cancelled: true)
    assert @contest.reload.settled?
    assert @contest.cancelled?

    get live_contest_path(@contest)

    assert_select "[data-test='live-state'][data-state='cancelled']"
    assert_select "[data-test='live-state']", text: /Cancelled/i
    assert_select "[data-test='live-state']", { text: /Final/i, count: 0 },
                  "cancelled outranks settled — the badge must say which one it is"
    assert_select "[data-test='live-state'] .animate-pulse", count: 0
  end

  # The tab title is the same claim in a smaller place, and it read "Live" too.
  test "the tab title reads cancelled for a cancelled, locked contest" do
    @contest.update!(starts_at: 1.hour.ago, status: "open", onchain_cancelled: true)

    get live_contest_path(@contest)

    assert_select "title", text: /Cancelled/
    assert_select "title", { text: /Live/, count: 0 }
  end

  # THE INVARIANT THIS FIX RETIRED, PINNED SO NOBODY RESTORES IT.
  #
  # The badge used to be documented as carrying "the same predicate the broadcast
  # filters on", so that it told you whether an update could arrive. That is no
  # longer true and must not be made true again: Contest::LiveBroadcast selects
  # `status: [:open]` then `.select(&:live?)`, and NEITHER filter excludes a
  # cancelled contest — so a cancelled, locked, unsettled contest is still in the
  # broadcast set while its badge says "Cancelled". The divergence is deliberate.
  # What a viewer needs first is that the contest is over and refunded; whether
  # score packets are still being pushed at the games strip is not the headline.
  test "the badge diverges from the broadcast predicate for a cancelled contest" do
    @contest.update!(starts_at: 1.hour.ago, status: "open", onchain_cancelled: true)
    @contest.reload

    assert @contest.live?, "the broadcaster's live? filter still admits this contest"
    assert_includes Contest.where(slate_id: @contest.slate_id, status: [:open]).select(&:live?),
                    @contest, "and it is genuinely still in the broadcast set"

    get live_contest_path(@contest)

    assert_select "[data-test='live-state'][data-state='cancelled']", { count: 1 },
                  "the badge names the state, NOT whether updates can arrive"
  end
end
