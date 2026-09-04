# frozen_string_literal: true

require "test_helper"

# THE FIVE-STEP SPLIT ONLY BUYS SOMETHING IF THE RUN STOPS BETWEEN THE STEPS.
#
# Measured 2026-09-04: an agent ran the whole rehearsal in one turn and the
# operator never saw a board mid-flight. Nothing was broken — the SOP contained
# no instruction to stop (grep for stop/wait/hand-back/pause returned nothing),
# so running create through close in sequence was the SOP as written.
#
# The halt therefore lives in the driver's OUTPUT, where the agent reads it at
# the moment it picks the next command, and these tests pin it there. A doc that
# is the only place a rule lives is a doc that drifts.
class QaRehearsalStepHaltTest < ActiveSupport::TestCase
  Driver = TurfMonster::QaRehearsal::Driver
  SOURCE = Rails.root.join("lib/turf_monster/qa_rehearsal/driver.rb").read.freeze

  # The five operator-facing steps. `conclude` is listed once here and gets its
  # own per-exit test below, because it is the step with branches.
  STEP_METHODS = %w[create_contest enter_cast play_preseason conclude close_contest].freeze

  def capture
    io = StringIO.new
    yield Driver.new(io: io)
    io.string
  end

  # Slice one method's body out of the source: from its `def` to the `end` at
  # the same indentation. Matching on indentation rather than counting `end`s
  # keeps this readable, and the guard below fails loudly if a body comes back
  # implausibly short rather than silently asserting on nothing.
  def body_of(method)
    lines = SOURCE.lines
    start = lines.index { |l| l =~ /^(\s*)def #{Regexp.escape(method)}\b/ }
    refute_nil start, "#{method} is not defined in driver.rb — did it get renamed?"
    indent = lines[start][/^\s*/]
    finish = (start + 1...lines.length).find { |i| lines[i] == "#{indent}end\n" }
    refute_nil finish, "could not find the end of #{method}"
    body = lines[start..finish].join
    assert_operator body.lines.length, :>, 3, "#{method} body came back too short to be real"
    body
  end

  # THE LOAD-BEARING TEST. A step added later with no halt fails here, which is
  # the whole point — the defect was a missing instruction, not a wrong one.
  test "every operator-facing step ends by halting for the operator" do
    missing = STEP_METHODS.reject { |m| body_of(m).include?("hand_back(") }

    assert_empty missing,
                 "these steps run to completion without handing back: #{missing.join(', ')}. " \
                 "A step that does not stop is a step the operator cannot watch."
  end

  # `conclude` is the step with branches, and one of them is the only step in
  # the driver that CANNOT proceed without him: the settle is 2-of-3 and the
  # server has signed one half, so a run that continues past --cosign link
  # closes a contest that never paid.
  test "all three conclude exits halt, including the link branch" do
    assert_equal 1, body_of("conclude").scan(/hand_back\(/).length,
                 "conclude's own body carries exactly the nobody-owed halt; " \
                 "the other two exits live in the branch methods asserted below"

    assert_includes body_of("offer_cosign_link"), "hand_back(",
                    "the attended branch is the one that REQUIRES him — it must never run on"
    assert_includes body_of("cosign_with_agent"), "hand_back(",
                    "the unattended branch still owes him the payout arithmetic"
  end

  test "the halt names what to confirm and what to run next" do
    out = capture { |d| d.send(:hand_back, verify: "entries read 3/29", next_command: "bin/x play") }

    assert_match(/STOP/, out)
    assert_match(/WAIT for his go-ahead/, out)
    assert_match(/entries read 3\/29/, out, "the halt must say what he is confirming, in checkable terms")
    assert_match(%r{Next, once he confirms:\s+bin/x play}, out)
  end

  # The last step has nothing to run next. Printing "Next: nil" there would read
  # as a step the agent failed to identify rather than the end of the run.
  test "the terminal halt says the rehearsal is complete instead of naming a next command" do
    out = capture { |d| d.send(:hand_back, verify: "the contest reads settled") }

    assert_match(/STOP/, out)
    assert_match(/last step. The rehearsal is complete/, out)
    refute_match(/Next, once he confirms/, out)
  end

  # The halt is worthless if it scrolls past inside a wall of log. It goes LAST.
  test "the halt is the last thing a step prints" do
    out = capture do |d|
      d.send(:say_urls, "qa-rehearsal-x")
      d.send(:hand_back, verify: "anything", next_command: "bin/x")
    end
    tail = out.lines.map(&:strip).reject(&:empty?).last

    assert_match(/─/, tail, "the halt's closing rule must be the last line, so it cannot be scrolled past")
  end
end
