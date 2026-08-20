# frozen_string_literal: true

# bin/lib/e2e_executed_set.rb — THE EXECUTED SET, read off the runner's own receipt.
#
# Asserts one property, and it is the only property that matters about a test lane:
#
#     THE LANE EXECUTED EXACTLY THE SPECS IT IS SUPPOSED TO EXECUTE.
#
# Not "the specs are declared". Not "the command looks right". EXECUTED — as reported by
# Playwright itself, in the JSON report it emits from the run that just happened.
#
# WHY THIS EXISTS, AND WHY THE STATIC GUARD WAS NOT ENOUGH.
# The hub pairs this with a static ratchet (test/lib/e2e_quarantine_ratchet_test.rb) that reads
# the committed source. Turf has no such ratchet yet — its exclusion is a whole FILE
# (devnet-smoke.spec.js) rather than scattered tags, so the count moves only when that file
# moves. This runtime gate is the half that matters; the static half is a follow-up. Read on
# for what the runtime half proves that source-reading cannot —
# 18 excluded == 51. That is a true and useful statement about what the suite DECLARES.
# It is not a statement about what RAN, and review of #543 killed three successive versions
# of this guard on exactly that gap. Every kill was the same event wearing a new spelling:
#
#   ROUND 1  `test.only(...)`             lane 51 -> 1 spec, three shards GREEN (an empty
#                                         shard exits 0 — sharding suppresses Playwright's
#                                         own "No tests found" guard).
#   ROUND 2  `test.skip` / `.fixme`       spec drops out; ci.yml command byte-identical.
#   ROUND 3  `testInfo.skip()`            MEASURED on this repo: exit 0, "1 skipped",
#            (the RECEIVER axis)          every static guard green. The source-level guard
#                                         anchored its receiver to `test|it|describe`, so a
#                                         different receiver walked straight past it.
#   ROUND 3  `--grep-invert '@devnet|wallet'`      the SANCTIONED exclusion, widened in one
#            (the FILTER axis)            edit: 51 -> 43 specs, every guard green. The
#                                         ratchet bounded the TAG and nothing bounded the
#                                         FILTER THAT CONSUMES IT.
#
# Three rounds, three axes — MODIFIER, RECEIVER, FILTER — and a fourth is always available,
# because a source-level guard can only refuse the spellings someone thought to refuse. The
# axes are not the disease. Reading the SOURCE is.
#
# So this gate reads the RECEIPT. A spec that did not run does not appear in the report as
# `expected`, whatever the reason it did not run and whatever the syntax used to arrange it:
# a runtime skip, a declaration modifier, a widened `--grep-invert`, a `--only-changed`, a
# narrowed `testDir`, a deleted file, a dropped shard, or next year's flag that nobody in
# this repo has heard of. They all land on the same line of arithmetic:
#
#     executed == total_specs - excluded            (config/e2e_lane.yml)
#
# A guard that enumerates spellings must be right every time. A guard that counts what ran
# has to be beaten by ARITHMETIC — and to move the arithmetic you must edit config/e2e_lane.yml,
# which is a reviewable diff line with a comment attached.
#
# WHAT THIS DELIBERATELY DOES NOT ASSERT: whether the specs PASSED. A failing spec is a red
# `playwright` job already; that verdict is not this gate's business. This gate answers the
# question the `playwright` job cannot answer about ITSELF: did it run everything it claimed?

require "json"
require "yaml"

class E2eExecutedSet
  # Playwright statuses. A test is EXECUTED if it reached a verdict — pass, fail, or flake.
  # `skipped` is the one status that means "this spec left the lane", which is the whole
  # event we are here to catch, on every axis at once.
  EXECUTED_STATUSES = %w[expected unexpected flaky].freeze
  SKIPPED_STATUS = "skipped"

  Report = Struct.new(:source, :doc, keyword_init: true)

  def self.load_contract(path)
    YAML.safe_load_file(path)
  end

  # Every *.json in the reports directory — one per shard, downloaded from the shard jobs'
  # artifacts. A report that is MISSING or UNPARSEABLE is a failure, never a pass: a shard
  # that died before writing its receipt is precisely a shard whose specs did not run.
  def self.load_reports(dir)
    paths = Dir.glob(File.join(dir, "**", "*.json")).sort
    paths.map do |path|
      Report.new(source: File.basename(path), doc: JSON.parse(File.read(path)))
    rescue JSON::ParserError => e
      Report.new(source: File.basename(path), doc: { "__parse_error__" => e.message })
    end
  end

  def initialize(contract:, reports:)
    @contract = contract
    @reports = reports
  end

  attr_reader :contract, :reports

  def expected_executed = contract.fetch("executed")
  def excluded_tag = contract.fetch("excluded_tag")

  # Walk the report's suite tree. Playwright nests suites per file and per describe-block, so
  # specs live at arbitrary depth; a flat read of `suites[].specs` silently misses everything
  # inside a `test.describe`, which would under-count and fire a confusing failure.
  def specs_in(doc)
    found = []
    walk = lambda do |node|
      Array(node["specs"]).each { |spec| found << spec }
      Array(node["suites"]).each { |child| walk.call(child) }
    end
    Array(doc["suites"]).each { |suite| walk.call(suite) }
    found
  end

  # A spec carries one `test` per project. Count TESTS, not specs — that is what Playwright's
  # own `--list` and `stats` count, so the contract's numbers mean the same thing here that
  # they mean when a human runs the command by hand.
  def tests_in(doc)
    specs_in(doc).flat_map do |spec|
      Array(spec["tests"]).map { |test| { "title" => spec["title"], "status" => test["status"] } }
    end
  end

  def all_tests = reports.flat_map { |report| tests_in(report.doc) }
  def executed_tests = all_tests.select { |test| EXECUTED_STATUSES.include?(test["status"]) }
  def skipped_tests = all_tests.select { |test| test["status"] == SKIPPED_STATUS }

  # An unsharded run reports no shard block; treat it as the only shard (1 of 1) so the
  # completeness check below reads the same for a local `npx playwright test` and for CI's
  # 3-way matrix.
  def shard_of(doc)
    shard = doc.dig("config", "shard")
    return { current: 1, total: 1 } unless shard

    { current: shard["current"], total: shard["total"] }
  end

  def failures
    checks = [
      parse_failures,
      shard_completeness_failures,
      report_shape_failures,
      skipped_failures,
      excluded_leak_failures,
      count_failures
    ]
    checks.flatten.compact
  end

  def ok? = failures.empty?

  def summary
    "#{executed_tests.size} executed · #{skipped_tests.size} skipped · " \
      "#{reports.size} shard report(s) · contract: #{expected_executed} executed " \
      "(#{contract.fetch("total_specs")} committed − #{contract.fetch("excluded")} excluded)"
  end

  private

  def parse_failures
    reports.filter_map do |report|
      next unless report.doc.key?("__parse_error__")

      "#{report.source} is not parseable JSON (#{report.doc["__parse_error__"]}). A shard " \
        "whose report is missing or corrupt is a shard whose specs cannot be shown to have " \
        "run — that is a RED verdict, not a pass."
    end
  end

  # The report must look like the thing we think we are reading. If Playwright ever changes
  # the report schema, this gate must FAIL LOUDLY rather than quietly walk an empty tree and
  # read "0 executed" as some other kind of problem — or, far worse, read a shape it does not
  # understand as zero and be "fixed" by someone lowering the contract.
  def report_shape_failures
    reports.filter_map do |report|
      next if report.doc.key?("__parse_error__")

      stats = report.doc["stats"]
      next "#{report.source} has no `stats` block — this is not a Playwright JSON report." unless stats.is_a?(Hash)

      counted = tests_in(report.doc).size
      claimed = EXECUTED_STATUSES.sum { |status| stats[status_key(status)].to_i } + stats["skipped"].to_i
      next if counted == claimed

      "#{report.source}: walked #{counted} test(s) out of the suite tree but its own `stats` " \
        "block claims #{claimed}. The report schema is not what this gate was written " \
        "against — FIX THE GATE (bin/lib/e2e_executed_set.rb), do not lower the contract."
    end
  end

  def status_key(status) = status

  def shard_completeness_failures
    parsed = reports.reject { |report| report.doc.key?("__parse_error__") }
    return [] if parsed.empty?

    shards = parsed.map { |report| shard_of(report.doc) }
    totals = shards.map { |shard| shard[:total] }.uniq

    if totals.size > 1
      return ["the shard reports disagree about how many shards there are (#{totals.inspect}). " \
              "Some of these came from a different run."]
    end

    total = totals.first
    seen = shards.map { |shard| shard[:current] }.sort
    want = (1..total).to_a
    return [] if seen == want

    ["expected one report from each of #{total} shard(s) — #{want.inspect} — but got " \
     "#{seen.inspect}. A shard whose report never arrived is a shard whose specs never ran, " \
     "and its ~#{expected_executed / [total, 1].max} specs are silently uncovered. This is " \
     "the DROPPED-SHARD vector: delete one entry from the ci.yml `shard:` matrix and every " \
     "remaining job stays green over a smaller suite."]
  end

  def skipped_failures
    return [] if skipped_tests.empty?

    titles = skipped_tests.map { |test| "  · #{test["title"]}" }.join("\n")
    ["#{skipped_tests.size} spec(s) were SKIPPED AT RUNTIME:\n#{titles}\n" \
     "A skipped spec exits 0 and reports green. This is the axis that no source-level guard " \
     "can close: `testInfo.skip()`, `test.info().skip()`, a destructured `const { skip } = " \
     "testInfo`, or a helper in another file that calls it for you — all identical here, all " \
     "invisible to a grep. If a spec is rotted there are two honest moves and no third: FIX " \
     "it, or move it into the excluded file (which makes you account for it in " \
     "config/e2e_lane.yml) and " \
     "BLOCK on /tasks/repair-rotted-e2e-specs."]
  end

  # The exclusion did what it says on the tin, and ONLY that. A excluded spec must not run
  # (it is red, it would break the lane); an executed spec must not carry the tag.
  def excluded_leak_failures
    leaked = executed_tests.select { |test| test["title"].to_s.include?(excluded_tag) }
    return [] if leaked.empty?

    ["#{leaked.size} executed spec(s) carry #{excluded_tag} in the title. The exclusion and " \
     "the contract have drifted apart: either the CI command lost its `--grep-invert`, or a " \
     "tag was added without lowering `executed` in config/e2e_lane.yml."]
  end

  # THE ARITHMETIC. Everything above is a named diagnosis; this is the catch-all that fires
  # for the vectors nobody has imagined yet, because they all reduce to the same thing.
  def count_failures
    actual = executed_tests.size
    return [] if actual == expected_executed

    delta = actual - expected_executed
    direction = delta.negative? ? "FEWER" : "MORE"

    ["the lane EXECUTED #{actual} spec(s); config/e2e_lane.yml pins it at #{expected_executed} " \
     "(#{delta.abs} #{direction} than the contract).\n" \
     "The green `playwright` check now covers a DIFFERENT SET than the one this repo signed " \
     "off on, and the source may look completely innocent — this assertion is deliberately " \
     "blind to HOW the set changed, because every previous version of this guard was defeated " \
     "by a HOW it had not enumerated.\n" \
     "If specs LEFT the lane, find out why before you touch this number. The known ways, none " \
     "of which change the spec count in the source: a widened `--grep-invert` in " \
     ".github/workflows/ci.yml (widening `@devnet` to `@devnet|wallet` would drop more), a `--only-changed` or " \
     "`--last-failed` flag, a `--max-failures` early exit, a narrowed `testDir`/`testIgnore`, " \
     "a dropped shard, or a runtime skip.\n" \
     "If you legitimately ADDED specs: raise `total_specs` AND `executed` in " \
     "config/e2e_lane.yml in the same commit, and confirm with `npx playwright test --list`."]
  end
end
