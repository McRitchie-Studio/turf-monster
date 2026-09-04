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

  # DERIVED FROM THE CLI, not typed here. A hardcoded list cannot keep the
  # promise this file makes — a sixth step added to bin/qa-contest-rehearsal
  # would simply not be in it, and the suite would stay green saying nothing.
  # `status` is excluded: it prints the manifest and is not a step of the run.
  CLI = Rails.root.join("bin/qa-contest-rehearsal").read.freeze
  STEP_METHODS = CLI.scan(/when "(?!status")[a-z]+"\s+then driver\.([a-z_]+)/).flatten.uniq.freeze

  def capture
    io = StringIO.new
    yield Driver.new(io: io)
    io.string
  end

  # Drive step 3 down one of its two exits with nothing real behind it — no
  # Rails, no DB, no desk — and hand back what it PRINTED. Stubbing the
  # collaborators is what lets the test assert on the branch instead of the
  # source text.
  def play_step_output(already_scored:)
    io = StringIO.new
    driver = Driver.new(io: io)
    manifest = Struct.new(:data) do
      def read = data
      def merge(*) = data
      def write(*) = data
    end.new({ "contest_slug" => "qa-rehearsal-x", "kickoff_shift_seconds" => 0 })

    driver.define_singleton_method(:guard!) { { app: "turf-monster-qa" } }
    driver.define_singleton_method(:manifest) { manifest }
    driver.define_singleton_method(:slate_already_scored?) { already_scored }
    driver.define_singleton_method(:unshift_fixture) { |_s| nil }
    driver.define_singleton_method(:lock_contest) { |_slug| nil }
    driver.define_singleton_method(:replay) { |_pace| :replayed }
    driver.define_singleton_method(:remote) { Struct.new(:x).new(nil).tap { |r| r.define_singleton_method(:call) { |_s| {} } } }
    # The reset path shells out to the ESPN poller; the paced path does not.
    driver.define_singleton_method(:system) { |*_args| true }

    driver.play_preseason(pace: 4, reset: false)
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

  # A source scan finds `hand_back(` ANYWHERE in the method, including on a
  # branch an early `return` jumps over — which is exactly how the paced re-run
  # of step 3 shipped unhalted while this file was green. It has now been wrong
  # in BOTH directions on this one method: green while unhalted, then red once
  # the halt moved into a tail helper. So it is kept only as a cheap net for a
  # step carrying no halt ANYWHERE, and it resolves one hop into the helpers a
  # step delegates to. The executing tests below hold the actual property.
  def halts?(method, depth: 1)
    body = body_of(method)
    return true if body.include?("hand_back(")
    return false if depth.zero?

    callees = body.scan(/^\s+(?:return )?([a-z_]+)\(/).flatten.uniq - [method]
    callees.any? { |c| SOURCE.match?(/^\s*def #{Regexp.escape(c)}\b/) && halts?(c, depth: depth - 1) }
  end

  # A derivation that silently returns [] makes every scan below vacuously
  # green. Pin the count and the members, so a CLI refactor that breaks the
  # regex fails HERE rather than quietly switching the guard off.
  test "the step list really derived from the CLI" do
    assert_equal %w[create_contest enter_cast play_preseason conclude close_contest],
                 STEP_METHODS,
                 "STEP_METHODS is scanned out of bin/qa-contest-rehearsal — an empty or " \
                 "partial list would make the halt scan pass while reading nothing"
  end

  test "no step method is missing a halt entirely" do
    missing = STEP_METHODS.reject { |m| halts?(m) }

    assert_empty missing,
                 "these steps reach no hand_back, directly or through a tail helper: " \
                 "#{missing.join(', ')}. This is the weak check — the per-exit tests are the real one."
  end

  # THE LOAD-BEARING TEST, and it RUNS the branch rather than reading it.
  #
  # `play --pace 4` is the string the SOP's step 3 and the driver's own step-2
  # hand-back both name, so this is the command an operator actually types. The
  # evergreen slate is one shared Slate and `replay` re-lays the Goal rows it
  # captured, so `slate_already_scored?` is false exactly once and true forever
  # after: the branch that skipped the halt is the one used every run but the
  # first.
  test "the paced re-run of step 3 halts, not just the first run" do
    out = play_step_output(already_scored: true)

    assert_match(/── STOP ─/, out,
                 "the paced re-run ended without handing back — this is the branch an operator uses most")
    assert_match(/conclude --cosign link/, out, "the halt must still name the next step")
  end

  test "the first run of step 3 halts too" do
    out = play_step_output(already_scored: false)

    assert_match(/── STOP ─/, out)
    assert_match(/conclude --cosign link/, out)
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
