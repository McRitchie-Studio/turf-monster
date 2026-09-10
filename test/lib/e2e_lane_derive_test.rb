# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"
require_relative "../../bin/lib/e2e_lane_derive"

# [unit] + [integration] for the derived half of the e2e lane contract.
#
# The bug being pinned is a SILENT MERGE. `total_specs` is derivable but was
# maintained by hand, so two branches that each add a spec write the same new
# value for DIFFERENT files. Identical text merges with no conflict, and the lane
# lands under-declared with nothing red. Four occurrences in one day.
class E2eLaneDeriveTest < ActiveSupport::TestCase
  LISTER_OUTPUT = <<~OUT
    [chromium] › entries.spec.js:4:1 › a contest entry persists
    [devnet] › devnet-smoke.spec.js:810:1 › @devnet 16 — standard contest

    Total: 200 tests in 54 files
  OUT

  CONTRACT = <<~YML
    # A comment that records a coverage decision and must survive a rewrite.
    total_specs: 200

    # Another load-bearing comment.
    excluded: 17
    allowed_skips: 4
    executed: 179
  YML

  # ---- unit ---------------------------------------------------------------

  test "the lister's total line is parsed into specs and files" do
    assert_equal({ specs: 200, files: 54 }, E2eLaneDerive.parse_total(LISTER_OUTPUT))
  end

  test "output without a total line yields nil rather than a guess" do
    assert_nil E2eLaneDerive.parse_total("Error: no tests found\n"),
               "an unparseable lister must be reported, never silently treated as zero"
  end

  # A count of zero is a REAL answer and a catastrophic one — it means the lane
  # collects nothing. It must not be confused with "could not parse".
  test "a zero total parses as zero, distinct from unparseable" do
    assert_equal({ specs: 0, files: 0 }, E2eLaneDerive.parse_total("Total: 0 tests in 0 files\n"))
  end

  test "executed is total minus excluded minus allowed skips" do
    assert_equal 179, E2eLaneDerive.expected_executed(200, 17, 4)
  end

  test "a rewrite changes only the two derived scalars and keeps every comment" do
    out = E2eLaneDerive.rewrite(CONTRACT, total_specs: 202, executed: 181)

    assert_includes out, "total_specs: 202"
    assert_includes out, "executed: 181"
    assert_includes out, "# A comment that records a coverage decision and must survive a rewrite."
    assert_includes out, "# Another load-bearing comment."
    assert_includes out, "excluded: 17", "a hand-declared value was rewritten; only derived ones may change"
    assert_includes out, "allowed_skips: 4", "a hand-declared value was rewritten"
  end

  test "agreement with the tree reports no disagreements" do
    contract = YAML.safe_load(CONTRACT)
    derived = E2eLaneDerive.derived_for(contract, 200)
    assert_empty E2eLaneDerive.disagreements(contract, derived)
  end

  # THE COLLISION ITSELF. Both branches added a spec; both wrote 200. The tree
  # actually holds 202, and the merge produced no conflict to notice.
  test "an under-declared counter is reported, not tolerated" do
    contract = YAML.safe_load(CONTRACT)
    derived = E2eLaneDerive.derived_for(contract, 202)
    problems = E2eLaneDerive.disagreements(contract, derived)

    assert_equal 2, problems.size, "both the total and the arithmetic are stale and both must be named"
    assert problems.any? { |p| p.include?("says 200") && p.include?("has 202") },
           "the message must state BOTH numbers; a reviewer should not have to re-derive it"
  end

  # ---- integration --------------------------------------------------------
  #
  # Drives the REAL script — real process, real YAML on disk, real exit codes —
  # against a temp tree with a FAKE lister on PATH. Hermetic on purpose: the rails
  # test job has no Node, and a test that quietly skipped there would assert
  # nothing while reporting green, which is the same class of bug as the one
  # under test.

  # The script runs the lister TWICE — once bare for the tree total, once with
  # `--grep @devnet` for the excluded count — so the fake has to tell them apart.
  # Feeding one number to both is not a harmless simplification: it makes `excluded`
  # equal `total_specs` and drives `executed` negative, which is how this helper
  # first reported the derive-excluded change as broken when it was correct.
  # The default excluded line matches CONTRACT's `excluded: 17`.
  def with_fake_lister(total_line, excluded_line = "Total: 17 tests in 1 file", contract: CONTRACT)
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config/e2e_lane.yml"), contract)

      bin = File.join(root, "fakebin")
      FileUtils.mkdir_p(bin)
      npx = File.join(bin, "npx")
      File.write(npx, <<~SH)
        #!/bin/sh
        for arg in "$@"; do
          if [ "$arg" = "--grep" ]; then
            echo '#{excluded_line}'
            exit 0
          fi
        done
        echo '#{total_line}'
      SH
      FileUtils.chmod(0o755, npx)

      script = File.expand_path("../../bin/e2e-lane-derive", __dir__)
      env = { "E2E_LANE_ROOT" => root, "PATH" => "#{bin}:#{ENV.fetch("PATH")}" }
      yield root, ->(*args) { Open3.capture2e(env, script, *args) }
    end
  end

  test "the script exits zero when the contract matches the tree" do
    with_fake_lister("Total: 200 tests in 54 files") do |_root, run|
      out, status = run.call
      assert status.success?, "a matching contract must pass: #{out}"
      assert_includes out, "GREEN"
    end
  end

  test "the script exits non-zero and names both numbers when the counter is stale" do
    with_fake_lister("Total: 202 tests in 55 files") do |_root, run|
      out, status = run.call
      refute status.success?, "a stale counter must FAIL the build, not warn"
      assert_includes out, "RED"
      assert_includes out, "says 200"
      assert_includes out, "has 202"
      assert_includes out, "bin/e2e-lane-derive --write", "the failure must carry its own fix"
    end
  end

  test "write re-derives the file in place and a re-check then passes" do
    with_fake_lister("Total: 202 tests in 55 files") do |root, run|
      _out, status = run.call("--write")
      assert status.success?

      written = File.read(File.join(root, "config/e2e_lane.yml"))
      assert_includes written, "total_specs: 202"
      assert_includes written, "executed: 181", "executed must be re-derived alongside the total"
      assert_includes written, "# Another load-bearing comment.", "the rewrite destroyed a comment"

      _again, recheck = run.call
      assert recheck.success?, "the file it just wrote must satisfy its own check"
    end
  end

  # A lister that cannot run is NOT a pass. This is the failure mode that would
  # otherwise turn the whole gate green-and-blind on any runner missing Node.
  test "a lister that fails is a build failure, never a pass" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config/e2e_lane.yml"), CONTRACT)
      bin = File.join(root, "fakebin")
      FileUtils.mkdir_p(bin)
      npx = File.join(bin, "npx")
      File.write(npx, "#!/bin/sh\necho 'boom' >&2\nexit 3\n")
      FileUtils.chmod(0o755, npx)

      script = File.expand_path("../../bin/e2e-lane-derive", __dir__)
      out, status = Open3.capture2e(
        { "E2E_LANE_ROOT" => root, "PATH" => "#{bin}:#{ENV.fetch("PATH")}" }, script
      )

      refute status.success?, "an unrunnable lister must fail the gate"
      assert_includes out, "cannot derive"
    end
  end

  # ---- excluded is DERIVED, not trusted -----------------------------------
  #
  # THE CASE THIS EXISTS FOR, walked exactly. Someone adds one @devnet spec:
  # the tree total goes 200 -> 201, TRUE excluded goes 17 -> 18, and TRUE
  # executed STAYS 179. A deriver that trusts the hand-declared 17 writes
  # executed 180 — and the new declared-set gate certifies that GREEN. The lane
  # then executes 179 and e2e_executed_set fails 30-45 minutes later wearing a
  # "specs LEFT the lane" diagnosis, pointing the next builder at a widened
  # --grep-invert that never happened.
  test "adding an excluded spec leaves executed unchanged and is written correctly" do
    with_fake_lister("Total: 201 tests in 55 files", "Total: 18 tests in 1 file") do |root, run|
      _out, status = run.call("--write")
      assert status.success?

      written = File.read(File.join(root, "config/e2e_lane.yml"))
      assert_includes written, "total_specs: 201"
      assert_includes written, "excluded: 18", "excluded must be derived from the tagged lister"
      assert_includes written, "executed: 179",
                      "executed must be UNCHANGED — the added spec is excluded, so it never " \
                      "enters the lane. Trusting the stale excluded would write 180 here."
    end
  end

  test "a stale excluded is reported on its own, before the arithmetic drifts" do
    with_fake_lister("Total: 200 tests in 54 files", "Total: 18 tests in 1 file") do |_root, run|
      out, status = run.call
      refute status.success?, "a declared excluded that disagrees with the tree must fail"
      assert_includes out, "excluded: config/e2e_lane.yml says 17"
      assert_includes out, "the tree has 18 tagged specs"
    end
  end

  # ---- --write must never announce a write it did not make ----------------
  #
  # rewrite/2 is String#sub, which silently no-ops when the anchor misses. A QUOTED
  # scalar is exactly such a miss, and the script used to print "rewrote …" and exit
  # 0 over a file it had not fully changed — leaving it MIXED (executed rewritten,
  # total_specs not) and reporting success. Announcing a write that did not happen is
  # the same failure class the whole gate exists to kill.
  QUOTED_CONTRACT = <<~YML
    total_specs: "200"
    excluded: 17
    allowed_skips: 4
    executed: 179
  YML

  test "a rewrite that did not land fails loudly instead of reporting success" do
    with_fake_lister("Total: 203 tests in 55 files", contract: QUOTED_CONTRACT) do |root, run|
      out, status = run.call("--write")

      refute status.success?,
             "the script announced a write it could not make and exited 0: #{out}"
      assert_includes out, "did NOT land"

      written = File.read(File.join(root, "config/e2e_lane.yml"))
      assert_includes written, 'total_specs: "200"',
                      "precondition: the quoted scalar is what the line-anchored sub misses"
    end
  end
end
