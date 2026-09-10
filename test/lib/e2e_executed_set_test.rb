# frozen_string_literal: true

# Unit tests for bin/lib/e2e_executed_set.rb — THE RECEIPT GATE.
#
# The gate itself is proved END-TO-END against real Playwright runs (see the PR's mutation
# table: a `testInfo.skip()` and a widened `--grep-invert` both go RED against genuinely
# emitted reports). These tests prove its LOGIC over synthetic receipts, so the failure modes
# can be exercised in milliseconds instead of six minutes of CI — including the ones that are
# expensive or impossible to stage for real, like a corrupt report or a shard that never
# uploaded.
#
# The property under test, on every axis at once:
#
#     THE LANE EXECUTED EXACTLY THE SPECS IT IS SUPPOSED TO EXECUTE.
#
# Run directly:
#   ruby -Itest test/lib/e2e_executed_set_test.rb
#
# One tier (backend shape):
#   [unit] the gate's verdict over hand-built Playwright JSON reports.

require "minitest/autorun"
require_relative "../../bin/lib/e2e_executed_set"

class E2eExecutedSetTest < Minitest::Test
  CONTRACT = {
    "total_specs" => 4,
    "excluded" => 1,
    "executed" => 3,
    "excluded_tag" => "@devnet",
    "shards" => 2
  }.freeze

  # A Playwright JSON report, in the shape Playwright actually emits — VERIFIED by running the
  # real thing and reading it back (top-level `config`/`suites`/`errors`/`stats`; specs nested
  # under suites; each spec carrying `tests[].status`).
  def report(source:, shard:, total:, specs:)
    tests = specs.map do |title, status|
      { "title" => title, "ok" => status == "expected", "tests" => [{ "status" => status }] }
    end

    stats = { "expected" => 0, "unexpected" => 0, "flaky" => 0, "skipped" => 0 }
    specs.each { |_title, status| stats[status] += 1 }

    doc = {
      "config" => { "shard" => { "current" => shard, "total" => total } },
      "suites" => [{ "title" => "e2e", "specs" => tests }],
      "errors" => [],
      "stats" => stats
    }

    E2eExecutedSet::Report.new(source: source, doc: doc)
  end

  def gate(reports, contract: CONTRACT) = E2eExecutedSet.new(contract: contract, reports: reports)

  def healthy_reports
    [
      report(source: "shard-1.json", shard: 1, total: 2,
             specs: [["landing page loads", "expected"], ["tasks page loads", "expected"]]),
      report(source: "shard-2.json", shard: 2, total: 2,
             specs: [["agents page loads", "expected"]])
    ]
  end

  # --- the baseline ------------------------------------------------------------------

  def test_unit_a_healthy_run_is_green
    assert_predicate gate(healthy_reports), :ok?
    assert_empty gate(healthy_reports).failures
  end

  # A FAILING spec still RAN. This gate counts execution, not success — the `playwright` job
  # already fails a red spec, and conflating the two would make this gate fire on every
  # ordinary test failure until somebody deleted it.
  def test_unit_a_failing_spec_still_counts_as_executed
    reports = [
      report(source: "shard-1.json", shard: 1, total: 2,
             specs: [["landing page loads", "unexpected"], ["tasks page loads", "flaky"]]),
      report(source: "shard-2.json", shard: 2, total: 2, specs: [["agents page loads", "expected"]])
    ]

    assert_predicate gate(reports), :ok?
  end

  # --- THE RECEIVER AXIS -------------------------------------------------------------

  # BLOCKER A, at the only place it can actually be caught. `testInfo.skip()` — and the
  # destructured `const { skip } = testInfo`, and a helper in another file that calls it for
  # you — are ALL indistinguishable here, which is the entire point: the gate never looks at
  # the source, so it cannot be beaten by a spelling of it.
  def test_unit_a_runtime_skip_is_red_however_it_was_spelled
    reports = [
      report(source: "shard-1.json", shard: 1, total: 2,
             specs: [["landing page loads", "skipped"], ["tasks page loads", "expected"]]),
      report(source: "shard-2.json", shard: 2, total: 2, specs: [["agents page loads", "expected"]])
    ]

    failures = gate(reports).failures

    refute_predicate gate(reports), :ok?
    assert_match(/SKIPPED AT RUNTIME/, failures.join)
    assert_match(/landing page loads/, failures.join)
    # And the arithmetic fires independently — 2 executed, contract says 3.
    assert_match(/EXECUTED 2 spec/, failures.join)
  end

  # ---- the DECLARED feature-flag allowance ---------------------------------------
  #
  # turf gates the Coinflow and Aeropay payment rails on ENABLE_COINFLOW / ENABLE_AEROPAY,
  # off in the default CI run, so 6 specs skip. Deliberate and documented in
  # e2e/financial.spec.js — and INVISIBLE until this gate's first real run found them:
  # 122 executed against a claimed 128, on a lane whose three shards ALL reported PASS.
  #
  # The allowance is therefore DECLARED in config/e2e_lane.yml, and one more than declared
  # is red. These two cases are the whole contract: at the allowance, green; over it, named
  # and red. Both were confirmed against REAL CI receipts before being written down —
  # green on run 32343994804's three shards, red when one passing spec in them is flipped.
  ALLOWED_SKIPS_CONTRACT = CONTRACT.merge("allowed_skips" => 1, "executed" => 2).freeze

  def test_unit_a_runtime_skip_within_the_declared_allowance_is_green
    reports = [
      report(source: "shard-1.json", shard: 1, total: 2,
             specs: [["Coinflow settled webhook acks", "skipped"], ["tasks page loads", "expected"]]),
      report(source: "shard-2.json", shard: 2, total: 2, specs: [["agents page loads", "expected"]])
    ]

    assert_empty gate(reports, contract: ALLOWED_SKIPS_CONTRACT).failures,
                 "one skip against an allowance of one must be GREEN — a stated, reviewed hole, " \
                 "not a silent one"
  end

  def test_unit_one_more_runtime_skip_than_declared_is_RED
    reports = [
      report(source: "shard-1.json", shard: 1, total: 2,
             specs: [["Coinflow settled webhook acks", "skipped"], ["tasks page loads", "skipped"]]),
      report(source: "shard-2.json", shard: 2, total: 2, specs: [["agents page loads", "expected"]])
    ]

    failures = gate(reports, contract: ALLOWED_SKIPS_CONTRACT).failures

    refute_empty failures, "two skips against an allowance of one must be RED"
    assert_match(/allows 1/, failures.join)
    assert_match(/tasks page loads/, failures.join,
                 "the gate must NAME the skipped specs — a count alone does not say which " \
                 "coverage was lost")
  end

  # --- THE FILTER AXIS ---------------------------------------------------------------

  # BLOCKER B. A widened `--grep-invert '@devnet|board'` does not SKIP the specs it
  # excludes — they never appear in the report at all. There is nothing to grep for and no
  # skip to count; the only trace it leaves anywhere in the system is that the number is
  # smaller. Which is exactly why the number is what this gate asserts.
  def test_unit_a_widened_exclusion_is_red_by_arithmetic_alone
    reports = [
      report(source: "shard-1.json", shard: 1, total: 2, specs: [["landing page loads", "expected"]]),
      report(source: "shard-2.json", shard: 2, total: 2, specs: [["agents page loads", "expected"]])
    ]

    failures = gate(reports).failures

    refute_predicate gate(reports), :ok?
    assert_match(/EXECUTED 2 spec\(s\); config\/e2e_lane\.yml pins it at 3/, failures.join)
    assert_match(/1 FEWER than the contract/, failures.join)
  end

  # --- THE SHARD AXIS ----------------------------------------------------------------

  # A NEW VECTOR: the shard whose report never arrived. Drop an entry from the ci.yml matrix,
  # or let a shard die before it uploads — the remaining jobs are green and the suite is a
  # third smaller. No source-level guard anywhere sees this.
  def test_unit_a_missing_shard_report_is_red
    failures = gate([healthy_reports.first]).failures

    assert_match(/expected one report from each of 2 shard/, failures.join)
    assert_match(/DROPPED-SHARD vector/, failures.join)
  end

  def test_unit_reports_from_different_runs_are_red
    reports = [
      report(source: "shard-1.json", shard: 1, total: 2, specs: [["a", "expected"]]),
      report(source: "shard-2.json", shard: 2, total: 3, specs: [["b", "expected"]])
    ]

    assert_match(/disagree about how many shards/, gate(reports).failures.join)
  end

  # --- FAILING SAFE ------------------------------------------------------------------

  # A corrupt receipt is not evidence of a passing lane. Failing OPEN here would rebuild the
  # original bug — a gate that credits a lane it never observed — inside the gate written to
  # kill it.
  def test_unit_a_corrupt_report_is_red
    corrupt = E2eExecutedSet::Report.new(source: "shard-2.json",
                                         doc: { "__parse_error__" => "unexpected token" })
    failures = gate([healthy_reports.first, corrupt]).failures

    assert_match(/not parseable JSON/, failures.join)
  end

  # If Playwright changes its report schema, this gate must say SO — loudly — rather than walk
  # an empty tree, read "0 executed", and get "fixed" by somebody lowering the contract to 0.
  def test_unit_a_report_whose_schema_we_do_not_understand_is_red
    alien = E2eExecutedSet::Report.new(
      source: "shard-1.json",
      doc: { "config" => {}, "suites" => [], "stats" => { "expected" => 40, "skipped" => 0,
                                                          "unexpected" => 0, "flaky" => 0 } }
    )

    assert_match(/report schema is not what this gate was written against/, gate([alien]).failures.join)
  end

  def test_unit_a_report_with_no_stats_block_is_red
    junk = E2eExecutedSet::Report.new(source: "shard-1.json", doc: { "hello" => "world" })

    assert_match(/not a Playwright JSON report/, gate([junk]).failures.join)
  end

  # --- THE EXCLUSION DID WHAT IT SAYS ------------------------------------------------

  # The excluded specs are RED — that is why they are excluded. If one EXECUTES, the CI
  # command and the contract have drifted apart, and the count alone might still add up.
  def test_unit_an_executed_excluded_spec_is_red
    reports = [
      report(source: "shard-1.json", shard: 1, total: 2,
             specs: [["landing page loads", "expected"], ["activities page loads @devnet", "expected"]]),
      report(source: "shard-2.json", shard: 2, total: 2, specs: [["agents page loads", "expected"]])
    ]

    failures = gate(reports).failures

    assert_match(/carry @devnet in the title/, failures.join)
  end

  # --- SPECS NESTED IN describe BLOCKS -----------------------------------------------

  # Playwright nests a suite per file AND per describe-block. A flat read of `suites[].specs`
  # misses everything inside a `test.describe` — which would UNDER-count and fire a confusing
  # red on a perfectly healthy lane. A guard that cries wolf gets deleted.
  def test_unit_counts_specs_nested_inside_describe_blocks
    doc = {
      "config" => { "shard" => { "current" => 1, "total" => 1 } },
      "suites" => [{
        "title" => "file.spec.js",
        "specs" => [{ "title" => "top level", "tests" => [{ "status" => "expected" }] }],
        "suites" => [{
          "title" => "a describe block",
          "specs" => [
            { "title" => "nested one", "tests" => [{ "status" => "expected" }] },
            { "title" => "nested two", "tests" => [{ "status" => "expected" }] }
          ]
        }]
      }],
      "stats" => { "expected" => 3, "unexpected" => 0, "flaky" => 0, "skipped" => 0 }
    }

    nested = E2eExecutedSet::Report.new(source: "shard-1.json", doc: doc)

    assert_predicate gate([nested]), :ok?
    assert_equal 3, gate([nested]).executed_tests.size
  end
end
