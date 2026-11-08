# frozen_string_literal: true

require "open3"

# E2eRepeatChanged — THE DETERMINISM CHECK AT THE DOOR.
#
# WHY. Alex McRitchie, 2026-11-06: "Flaky is a terrible way to describe a system." A
# spec that goes red then green at the same SHA is a defect with a cause. The cheapest
# place to find that cause is before the merge, while the author still holds the
# spec: every Playwright spec a PR adds or changes runs FIVE TIMES in the PR's own
# `playwright` lane (`--repeat-each 5`). A race the suite would hit one run in five
# turns the PR red now, instead of turning somebody else's PR red next week.
#
# WHAT IT RUNS. The PR's merge commit (what `pull_request` checks out) against its
# first parent, the base tip: the specs under e2e/ the PR added, changed or renamed,
# minus any it deleted. No spec changed, or not a pull request: it says so and runs
# nothing.
#
# FIVE FRESH PASSES, NOT `--repeat-each 5` IN ONE BOOT. Ported from mcritchie-studio
# (task deterministic-ci; Turf's half is turf-deterministic-ci), where a spec under
# `--repeat-each` met the seed its first repeat consumed, a red the lane never meets.
# Turf's specs reseed per spec (POST /test/reseed), but a boot holds more than the
# database (the per-process caches and the server's own state), so the rule is the
# same: each pass is its own `npx playwright test`, whose webServer re-runs
# db:test:prepare and e2e/seed.rb (playwright.config.js): five runs exactly as the
# lane runs them once. The passes are dealt round-robin over the shards (shard 1 of 3 runs
# passes 1 and 4), so no shard boots more than twice.
#
module E2eRepeatChanged
  PASSES = 5
  SPEC = %r{\Ae2e/.+\.spec\.js\z}

  module_function

  # PURE. `git diff --name-status` lines → the specs to repeat, sorted.
  # "M\te2e/a.spec.js", "A\te2e/b.spec.js", "R100\te2e/old.spec.js\te2e/new.spec.js", "D\t…".
  def changed_specs(name_status)
    name_status.to_s.each_line.filter_map do |line|
      status, *paths = line.chomp.split("\t")
      next if status.to_s.start_with?("D")

      path = paths.last.to_s
      path if path.match?(SPEC)
    end.uniq.sort
  end

  # PURE. The passes (1..PASSES) this shard runs: dealt round-robin, so shard K of N
  # runs passes K, K+N, … Unsharded, every pass.
  def passes(shard = nil)
    all = (1..PASSES).to_a
    return all unless shard

    k, n = shard.split("/").map(&:to_i)
    all.select { |p| (p - 1) % n == k - 1 }
  end

  # PURE. One pass's Playwright command, or nil when there are no specs.
  # @devnet stays out exactly as in the suite step (ci.yml): those specs need live
  # devnet and run only by hand (e2e/DEVNET_RUNBOOK.md). The list reporter only, so no
  # pass writes an executed-set receipt.
  def command(specs)
    return nil if specs.empty?

    ["npx", "playwright", "test", *specs, "--grep-invert", "@devnet", "--reporter=list"]
  end

  # The diff the PR brings, read from the merge commit's first parent. A shallow
  # checkout holds one commit, so the parent is fetched first (by SHA, as GitHub allows).
  def name_status(env: ENV, run: method(:capture))
    return nil unless env["GITHUB_EVENT_NAME"].to_s.start_with?("pull_request")

    sha = env.fetch("GITHUB_SHA", "HEAD")
    run.call(["git", "fetch", "--no-tags", "--depth=2", "origin", sha])
    out, ok = run.call(["git", "diff", "--name-status", "-M", "#{sha}^1", sha])
    ok ? out : nil
  end

  def capture(argv)
    out, _err, status = Open3.capture3(*argv)
    [out, status.success?]
  end
end
