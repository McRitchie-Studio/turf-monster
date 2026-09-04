# frozen_string_literal: true

require "test_helper"

# WHAT THE LIVE BOARD CALLS ITSELF.
#
# The page renders in every contest state now — a link an operator has should
# work — but its header announced "Live", with a pulsing red dot, unconditionally.
# So a contest that had not kicked off and one that had already paid out both
# claimed to be in progress. The badge is the first thing read on that page.
#
# The label tracks `Contest#live?`, which is the SAME predicate
# Contest::LiveBroadcast filters on when it decides whether to send. So the
# badge is not decoration: it tells you whether an update can arrive at all.
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

  # The badge must agree with the thing that decides whether updates arrive.
  # If these ever diverge, the page tells you it is live while the broadcaster
  # has already stopped sending to it.
  test "the badge agrees with the predicate the broadcaster filters on" do
    @contest.update!(starts_at: 1.hour.ago, status: "open")
    assert_equal :live, contest_live_state(@contest.reload)
    assert @contest.live?

    @contest.update!(status: "settled")
    assert_equal :final, contest_live_state(@contest.reload)
    refute @contest.live?
  end
end
