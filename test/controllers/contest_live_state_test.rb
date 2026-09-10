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
# cancelled, then final, then concluded, then live, then upcoming. Each guard is
# checked before any predicate it definitionally implies. Cancellation is a
# boolean orthogonal to `status`, so it can be true alongside any of the others;
# it wins outright because it is the state that tells a viewer to stop waiting
# on a result.
#
# TWO FIXES HERE HAVE NOW BEEN THE SAME BUG. Both times the helper mapped the
# axes its author had in mind and missed one that `live?` does not mention:
# first `cancelled?`, then `concluded?`. `live?` is `locked? && !settled?` and
# carries neither term, so a cancelled contest and a concluded-but-ungraded
# contest each satisfied it and each pulsed "Live". The full five-predicate
# state space, and the pairings that cannot occur, live in the comment above
# ContestsHelper::LIVE_STATES.
#
# These tests assert on what the PAGE renders, not on what the helper returns.
# A helper can return the right symbol into a view that ignores it, and the
# label and the pulse are two independently breakable halves — so every case
# below pins the label text, the state attribute, AND the presence or absence
# of the pulse. The one pre-existing test that asserted a return value was the
# test encoding the invariant that CAUSED the original bug; do not reintroduce
# that style here.
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
  # pulsing, on a terminal cancelled contest. ("Cancelled" is not "refunded":
  # cancel_contest returns the prize pool to the CREATOR and entry fees stay
  # operator revenue — contest.rb#cancelled?, ContestsHelper#contest_live_state.)
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
                  "a cancelled contest must not announce itself as in progress"
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
  # What a viewer needs first is that the contest is terminal and no result is
  # coming — not that they have been paid, which cancelling does not do for an
  # entrant; whether score packets are still being pushed at the games strip is
  # not the headline.
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

  # ---------------------------------------------------------------------------
  # CONCLUDED — the fifth predicate, and the second time this helper has been
  # fixed by adding an axis `live?` never mentioned.
  # ---------------------------------------------------------------------------

  # THE BUG. `concluded?` is `settled? || now >= concludes_at`; `live?` is
  # `locked? && !settled?` and has no conclusion term. So a contest whose games
  # are over and whose result is final, but which has not been graded, answers
  # live? TRUE — and the header pulsed "Live" at a finished contest.
  test "a concluded but ungraded contest reads as concluded, not live" do
    @contest.update!(starts_at: 2.hours.ago, concludes_at: 1.minute.ago, status: "open")
    @contest.reload
    assert @contest.live?,
           "the bug needs live? to be TRUE here — without that this test proves nothing"
    assert @contest.concluded?
    refute @contest.settled?, "ungraded: the fix must not depend on settle! having run"

    get live_contest_path(@contest)

    assert_response :success
    assert_select "[data-test='live-state'][data-state='concluded']"
    assert_select "[data-test='live-state']", text: /Concluded/i
    assert_select "[data-test='live-state']", { text: /Live/i, count: 0 },
                  "a contest whose games are over must not announce itself as in progress"
  end

  # THE OTHER HALF, ASSERTED SEPARATELY. The label and the dot are set from two
  # different keys of LIVE_STATES and break independently — a badge reading
  # "Concluded" while still pulsing red is the same lie at a glance.
  test "a concluded contest does not pulse and does not wear the live red dot" do
    @contest.update!(starts_at: 2.hours.ago, concludes_at: 1.minute.ago, status: "open")

    get live_contest_path(@contest)

    assert_select "[data-test='live-state'] .animate-pulse", { count: 0 },
                  "motion is reserved for live; a concluded contest is static"
    assert_select "[data-test='live-state'] .bg-red-500", { count: 0 },
                  "the concluded dot must not reuse live's red"
    assert_select "[data-test='live-state'] .bg-orange-500", { count: 1 },
                  "the concluded dot is the app's conclusion orange"
  end

  # The tab title is the same claim in a smaller place.
  test "the tab title reads concluded for a concluded, ungraded contest" do
    @contest.update!(starts_at: 2.hours.ago, concludes_at: 1.minute.ago, status: "open")

    get live_contest_path(@contest)

    assert_select "title", text: /Concluded/
    assert_select "title", { text: /Live/, count: 0 }
  end

  # CONCLUDED WITHOUT A LOCK IS REACHABLE, and it read "Not started".
  #
  # On chain, set_contest_conclusion_time requires conclusion > lock ONLY when a
  # lock is set. With no on-chain lock the contest's `starts_at` is nil, and
  # `starts_in_at` falls back to the SLATE's schedule — a Rails-side value the
  # chain never constrained. A slate starting later plus a conclusion already
  # passed is therefore a genuine state, and it is not `live?`, so the previous
  # fix could not have caught it either.
  test "a concluded contest that never locked reads as concluded, not not-started" do
    @contest.update!(starts_at: nil, concludes_at: 1.minute.ago, status: "open")
    @contest.reload
    refute @contest.locked?, "this row is specifically the NOT-locked one"
    refute @contest.live?, "and it is not live, so the live? branch cannot reach it"
    assert @contest.concluded?

    get live_contest_path(@contest)

    assert_response :success
    assert_select "[data-test='live-state'][data-state='concluded']"
    assert_select "[data-test='live-state']", text: /Concluded/i
    assert_select "[data-test='live-state']", { text: /Not started/i, count: 0 },
                  "a contest with a final result is not waiting to begin"
    assert_select "[data-test='live-state'] .animate-pulse", count: 0
  end

  # PRECEDENCE, THE DEFINITIONAL DIRECTION. `concluded?` returns true
  # unconditionally for a settled contest — even with concludes_at in the FUTURE
  # (contest.rb:595). So `final` must be asked before `concluded`, or every
  # settled contest in the app would relabel itself "Concluded".
  test "settled outranks concluded even when concludes_at is still in the future" do
    @contest.update!(starts_at: 2.hours.ago, concludes_at: 1.hour.from_now, status: "settled")
    @contest.reload
    assert @contest.concluded?,
           "settled forces concluded? true regardless of the timestamp — the ordering trap"

    get live_contest_path(@contest)

    assert_select "[data-test='live-state'][data-state='final']"
    assert_select "[data-test='live-state']", text: /Final/i
    assert_select "[data-test='live-state']", { text: /Concluded/i, count: 0 },
                  "a graded contest is Final; Concluded would understate it"
    assert_select "[data-test='live-state'] .animate-pulse", count: 0
  end

  # And the terminal flag still wins over the finished-games one.
  test "cancelled outranks concluded when both apply" do
    @contest.update!(starts_at: 2.hours.ago, concludes_at: 1.minute.ago,
                     status: "open", onchain_cancelled: true)
    @contest.reload
    assert @contest.concluded?
    assert @contest.cancelled?

    get live_contest_path(@contest)

    assert_select "[data-test='live-state'][data-state='cancelled']"
    assert_select "[data-test='live-state']", text: /Cancelled/i
    assert_select "[data-test='live-state']", { text: /Concluded/i, count: 0 },
                  "cancellation is terminal; concluded would suggest a result is coming"
    assert_select "[data-test='live-state'] .animate-pulse", count: 0
  end

  # THE STATE THAT MUST KEEP PULSING. Adding a guard ahead of `live` is exactly
  # how a fix over-reaches, so pin the row that is still genuinely in progress:
  # locked, ungraded, and with a conclusion that has NOT yet passed.
  test "a locked contest whose conclusion has not passed still reads live and pulses" do
    @contest.update!(starts_at: 2.hours.ago, concludes_at: 1.hour.from_now, status: "open")
    @contest.reload
    refute @contest.concluded?
    assert @contest.live?

    get live_contest_path(@contest)

    assert_select "[data-test='live-state'][data-state='live']"
    assert_select "[data-test='live-state']", text: /Live/i
    assert_select "[data-test='live-state'] .animate-pulse", { count: 1 },
                  "the concluded guard must not steal the state it sits in front of"
  end
end
