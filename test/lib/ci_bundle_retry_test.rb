# frozen_string_literal: true

# Guard test for the CI RubyGems-propagation wait — the contract that no job
# installs gems before checking that the versions it is about to install are
# actually visible on the index this runner resolves through.
#
# WHY THIS TEST EXISTS. `bin/release prepare` publishes a gem, commits the
# consumer `Gemfile.lock` bump onto `origin/release`, and that commit triggers
# CI seconds later. A job whose bundler cache misses then goes to the network
# for a version published moments ago — and RubyGems does not serve a new
# version from every CDN edge at once. `bundle install` dies with exit code 7
# and the actively misleading claim that the author "has removed" a version that
# is perfectly live.
#
# It is not hypothetical and it is not rare. It fired on BOTH releases of
# 2026-08-16, in different repos and different jobs:
#   · rel-20260816-92c013 — mcritchie-studio `lint`   @ abfdcf8 (run 31928197053)
#   · rel-20260816-53fa78 — turf-monster    `scan_js` @ 5302c71 (run 31931534886)
# Each time the pre-QA gate read the red, ABORTED the sweep, and stranded a
# release candidate AFTER every irreversible step (promote, publish, tag, lock
# bump) had already succeeded. Each time a plain re-run of the failed job went
# green on the SAME SHA with no code change — which is what proves it transient
# rather than a regression. The tell: sibling jobs on the same commit bundled
# fine, because they restored a usable cache and never hit the network at all.
#
# WHY A WAIT AND NOT A RETRY. The obvious fix is to let `Set up Ruby` fail and
# retry it. That requires `continue-on-error: true` on the setup step — and
# test/lib/ci_workflow_triggers_test.rb forbids that key anywhere in this
# workflow, on the hard-won grounds that a lane which RUNS, FAILS, and reports
# GREEN is the same lie as a lane that runs nothing. That guard has been through
# five rounds of review specifically for overclaiming, and its doctrine is to
# pin one correct shape rather than accumulate exceptions. Rather than carve a
# hole in it, this fix removes the failure instead of tolerating it: the wait
# runs BEFORE the install, and cannot fail the job at all.
#
# WHY THE WAIT RUNS ON THE RUNNER. The sweep already waits for the compact index
# before bumping consumer locks, and that wait PASSED both times. A check from
# the conductor's machine proves only what the conductor's CDN edge serves; it
# cannot speak for the edge a GitHub runner will hit minutes later. The script
# polls the same host from the same network, seconds before the install.
#
# THE INVARIANT, POSITIVE. This file does not enumerate ways a workflow can get
# this wrong; it asserts the property directly over EVERY workflow in the repo:
# any step that installs gems (`bundler-cache: true`) is immediately preceded by
# a step that runs the await script. "Immediately" is load-bearing — a wait that
# drifts to some earlier point in the job stops being a wait for THIS install.
#
# The final count assertion is the load-bearing one. Without it, a refactor that
# renamed the action or moved the workflows would make this test pass by
# examining nothing at all, which is the failure mode catalogued in
# docs/agents/audits/release-gate-and-devops-process-review-2026-07-12.md.

require "minitest/autorun"
require "yaml"

class CiBundleRetryTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  WORKFLOW_GLOB = File.join(ROOT, ".github/workflows/*.yml")
  AWAIT_SCRIPT = "await-gem-propagation.sh"

  def workflow_paths
    paths = Dir[WORKFLOW_GLOB].sort
    refute_empty paths, "no workflows found at #{WORKFLOW_GLOB} — this guard is looking in the wrong place"
    paths
  end

  # Every step that INSTALLS gems, with the step before it, so a failure names
  # the exact site instead of just "somewhere in CI".
  def gem_installing_steps
    workflow_paths.flat_map do |path|
      doc = YAML.load_file(path, aliases: true) || {}
      (doc["jobs"] || {}).flat_map do |job_name, job|
        steps = (job || {})["steps"] || []
        steps.each_with_index.filter_map do |step, index|
          next unless step.is_a?(Hash)
          next unless step["uses"].to_s.start_with?("ruby/setup-ruby@")
          next unless (step["with"] || {})["bundler-cache"] == true

          {
            label: "#{File.basename(path)} job=#{job_name} step[#{index}]",
            previous: index.positive? ? steps[index - 1] : nil
          }
        end
      end
    end
  end

  def test_the_await_script_is_executable_and_fail_soft
    script = File.join(ROOT, ".github/scripts", AWAIT_SCRIPT)

    assert File.exist?(script), "#{script} is missing — every workflow step below invokes it"
    assert File.executable?(script), "#{script} is not executable, so `run:` will fail with permission denied"

    body = File.read(script)
    code = body.lines.reject { |l| l.strip.start_with?("#") }.join

    # POSITIVE form. The previous spelling of this guard refuted exactly
    # `/^\s*exit\s+1\b/` and nothing else, so `set -euo pipefail` and `exit 2`
    # both passed GREEN while being just as fatal — a guard that names one
    # spelling of a failure and calls the class closed. Assert the property
    # instead: EVERY exit in the script is exit 0, and errexit is never armed.
    exits = code.scan(/^\s*exit\s+(\S+)/).flatten
    refute_empty exits, "the await script has no explicit exit — it must end in an explicit `exit 0`"

    non_zero = exits.reject { |c| c == "0" }
    assert_empty non_zero,
                 "the await script must stay FAIL-SOFT and every exit must be `exit 0`; found #{non_zero.inspect}. " \
                 "It runs before the install in every job, so any hard exit turns a CDN hiccup into a brand-new " \
                 "way for CI to go red — the exact opposite of why it exists"

    # `set -e` (in any bundle: -e, -eu, -euo pipefail) makes the NEXT failing
    # command fatal without an `exit` line anywhere, which is how a fail-soft
    # script stops being fail-soft while still reading as one.
    set_flags = code.scan(/^\s*set\s+-([a-zA-Z]+)/).flatten
    errexit = set_flags.select { |f| f.include?("e") }
    assert_empty errexit,
                 "the await script must not arm errexit (`set -#{errexit.first}`): with it, any failing command " \
                 "aborts the step and fails the job, with no `exit` line for the check above to catch"
  end

  # The whole point of the wait is WHICH FILE it asks about. `/info/<gem>` is a
  # correlated proxy — the two files publish together — but bundler's "can no
  # longer be found" is raised from the resolver's version list, built from
  # `/versions`, and a stale `/versions` additionally makes bundler trust its
  # cached `/info` and skip re-fetching it. A script that polls only `/info` can
  # therefore read fresh while the install still fails, which is exactly what
  # shipped first. This pins the corrected mechanism so it cannot silently
  # regress to the proxy.
  def test_the_await_script_polls_the_versions_list_bundler_resolves_through
    body = File.read(File.join(ROOT, ".github/scripts", AWAIT_SCRIPT))
    code = body.lines.reject { |l| l.strip.start_with?("#") }.join

    assert_includes code, "index.rubygems.org/versions",
                    "the await script must poll /versions — the list bundler's resolver is built from. " \
                    "/info alone is a proxy that can read fresh while the install still fails"

    assert_match(/--range\s+"?-/, code,
                 "/versions is ~23MB, so it must be read with an HTTP range request on the tail; " \
                 "a full GET per job is not an acceptable cost")
  end

  def test_every_gem_installing_step_waits_for_propagation_first
    sites = gem_installing_steps

    sites.each do |site|
      previous = site[:previous]

      refute_nil previous,
                 "#{site[:label]}: nothing precedes this gem install, so nothing waits for the versions it needs"

      assert_includes previous["run"].to_s, AWAIT_SCRIPT,
                      "#{site[:label]}: the step immediately before a gem install must run #{AWAIT_SCRIPT}. " \
                      "A wait placed anywhere earlier in the job is not a wait for THIS install."
    end

    # Vacuity guard: a green here must mean "every site checked out", never
    # "there were no sites to check".
    assert_operator sites.length, :>=, 1,
                    "found no `bundler-cache: true` setup-ruby steps in #{WORKFLOW_GLOB} — " \
                    "either the workflows moved or the action was renamed, and this guard is now asserting nothing"
  end
end
