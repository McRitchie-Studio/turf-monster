# frozen_string_literal: true

# Guard test for .github/workflows/ci.yml's PUSH TRIGGERS — the contract that every
# SHIPPABLE TIP earns an independent clean-env CI verdict.
#
# Ported from mcritchie-studio PR #512 (feat/run-ci-on-release-branch, the pass-3
# guard) for task ci-on-satellite-release. Keep the two copies in sync deliberately,
# not automatically — if the studio guard grows a vector, port it here on purpose.
#
# Why this test exists: `pull_request` only certifies a PR's own head. The sweep
# (`bin/release prepare`, run from mcritchie-studio) merges several approved PRs into
# this repo's `release` branch, producing a NEW merge-commit SHA whose COMBINED
# behavior no CI run has executed. That merge commit is what QA deploys and what
# `bin/release ship` fast-forwards into `main`. Until task ci-on-satellite-release,
# turf-monster triggered CI on `main` only — the release tip shipped with the local G3
# gate as its sole verdict. Dropping `release` from the push trigger silently restores
# that blind spot with no other test failing, so this asserts it directly.
#
# Run directly:
#   ruby -Itest test/lib/ci_workflow_triggers_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# HOW TO EXTEND THIS FILE — read before adding a vector.
#
# This guard was blocked THREE times in review of mcritchie-studio PR #512, and every
# hole had the same shape: the guard enumerated the ways the suite might NOT run, and
# each reviewer found a spelling one level of nesting away from where the last one
# looked (`github.ref` → missed `event_name`; job-level → missed step-level). A
# blacklist only ever catches the vectors its author already imagined. It is a
# scoreboard, not a guard.
#
# So the PRIMARY guard here is POSITIVE and lives in
# `test_integration_the_suite_runs_UNCONDITIONALLY_on_a_release_push`: some step must
# actually invoke the suite (TEST_COMMAND), and the lane that does must carry NO `if:`
# at all. That closes the whole CLASS — `env.SKIP_TESTS`, `inputs.fast`, a matrix flag,
# and every spelling not yet invented fail it, without anyone having to predict them.
# The enumerated list below is DEFENSE IN DEPTH behind it. When you add a vector, ask
# first whether the positive invariant already covers it; prefer strengthening that.
#
# SEVEN ways the release tip loses its verdict while `branches: [main, release]` still
# reads correct in the file — all seven asserted, because a guard is only worth the
# regressions it actually catches:
#   1. the branch is dropped from the push trigger (the obvious one);
#   2. a job opts out via a job-level `if:` on the github event context — `github.ref`,
#      `github.event_name == 'pull_request'`, or `github.base_ref`. The job reports a
#      GREEN required check having run zero tests on the RC tip;
#   3. the same `if:` moves onto the load-bearing STEP — the worse spelling, because the
#      job's other steps still succeed, so the job (and the required check) stays green
#      over zero tests. Job-level detection alone misses it (hole found in the second
#      review pass of mcritchie-studio PR #512);
#   4. a `paths`/`paths-ignore` filter on the push trigger suppresses the workflow RUN
#      outright, so a docs-only release merge commit gets no CI at all;
#   5. a `concurrency:` group lets a rapid second release push cancel or supersede the
#      first SHA's run — `cancelled` reads as RED to a SHA-addressed auditor: a false
#      alarm on a healthy candidate. Back-to-back release pushes are normal (sweep
#      merge, then re-pin);
#   6. `continue-on-error: true` on the suite's job or step — the INVERSE trick: the lane
#      RUNS, the tests FAIL, and it reports GREEN anyway. Zero-tests-green and
#      failing-tests-green are the same lie told to the RC tip;
#   7. the suite COMMAND itself is gutted — `run: echo "skipping"`, the `test` job
#      deleted or renamed, the command narrowed to a single file. No `if:`, no filter, no
#      `continue-on-error`: there is NOTHING for a blacklist to match, which is precisely
#      why the positive invariant has to be the primary guard. (6 and 7 were both
#      mutation-confirmed FALSE-GREEN against the blacklist alone.)
#
# CONSIDERED AND DELIBERATELY NOT ASSERTED — do not add these without a reason:
#   · a `matrix:` whose `exclude` empties the job → zero job instances, so the check is
#     MISSING, not green. Missing is a no-verdict, which fails SAFE: required checks
#     block and the auditor sees no data. Only false GREEN is silent.
#   · a `needs:` on a job that never runs → the dependent is skipped transitively, but
#     the ROOT skip is already caught by vectors 2/3. Asserting the transitive case adds
#     nothing the root doesn't.
#   · `if:` on the `on:` block itself → GitHub Actions has no such construct. N/A.
#   · branch-protection / required-check configuration → real, and a genuine way to
#     accept a green-with-no-runs tip, but it lives in GitHub settings, not in this repo.
#     Out of this file's contract; worth its own audit.
#
# NOTE the DOUBLE RUN the trigger creates, so nobody "fixes" it into hole #5: a release
# SHA gets its run from `push: release`, then `bin/release ship` fast-forwards main to
# the byte-identical SHA and fires a SECOND full run (including the test + test:system
# lane). Benign — the SHA-addressed auditor folds a pending duplicate as no-data, never
# a block — and expected.
#
# Two tiers (backend shape):
#   [unit]        the trigger-extraction and skip-detection logic, over fixture YAML —
#                 including the `on:`-parses-as-`true` trap that makes a naive guard
#                 vacuous, and each opt-out spelling above.
#   [integration] the REAL committed ci.yml satisfies the contract (both tips covered,
#                 pull_request intact, no job skipped, no path filter).

require "minitest/autorun"
require "yaml"

class CiWorkflowTriggersTest < Minitest::Test
  CI_YML = File.expand_path("../../.github/workflows/ci.yml", __dir__)

  # THE TRAP this helper exists for: in YAML 1.1 — which Ruby's Psych implements —
  # the bare key `on` is a BOOLEAN, so a workflow's `on:` block parses under the key
  # `true`, NOT `"on"`. A guard written as `yaml["on"]` reads nil, silently asserts
  # nothing, and passes forever even with the trigger deleted. Read both key forms so
  # this test keeps working if Psych ever moves to YAML 1.2 (where `on` stays a string).
  # The `on:` block. EVERY reader goes through here — reaching for `doc[true]` directly
  # anywhere else re-opens the trap for whichever accessor forgot.
  def triggers(yaml_text)
    doc = YAML.safe_load(yaml_text)
    doc[true] || doc["on"] || {}
  end

  def push_trigger(yaml_text)
    push = triggers(yaml_text)["push"]
    push.is_a?(Hash) ? push : {}
  end

  def push_branches(yaml_text)
    Array(push_trigger(yaml_text)["branches"])
  end

  # Every job that opts OUT of the release-push verdict via a job-level `if:`.
  #
  # There is no single spelling of this skip, and assuming there was is how the first
  # cut of this guard shipped with a hole. A cost-conscious engineer reaches for
  # `github.event_name == 'pull_request'` at least as readily as a `github.ref`
  # comparison — and either one keeps `release` in the trigger while producing a job
  # that runs NOTHING on the release tip: a green required check over zero tests, which
  # is the exact failure this workflow change exists to eliminate, one level up.
  # `github.base_ref` (set only on pull_request events) is a third spelling of the same
  # opt-out. Match the whole family; a new context key is the way this regresses next.
  SKIP_CONTEXT_KEYS = /github\.(ref|event_name|base_ref)/

  # A path filter on the PUSH trigger is a second, quieter way to strand the RC tip: it
  # suppresses the workflow RUN, so there are no jobs to skip and no checks to go green
  # — the release merge commit simply gets no CI at all.
  PATH_FILTER_KEYS = %w[paths paths-ignore].freeze

  # Everywhere a `concurrency:` block could sit: the workflow root and each job. ANY
  # group is a hazard here, not just `cancel-in-progress: true` — a group without it
  # still supersedes the QUEUED run when the next push lands, marking the first SHA
  # `cancelled`, and `cancelled` reads as RED to a SHA-addressed auditor.
  def concurrency_holders(yaml_text)
    doc = YAML.safe_load(yaml_text)
    holders = doc.key?("concurrency") ? ["workflow"] : []
    holders + doc.fetch("jobs", {}).select { |_name, job| job.is_a?(Hash) && job.key?("concurrency") }.keys
  end

  def jobs_skipping_release_push(yaml_text)
    YAML.safe_load(yaml_text).fetch("jobs", {}).select do |_name, job|
      next false unless job.is_a?(Hash)

      # Job-level `if:` AND every step-level `if:`. A skip on the load-bearing step is
      # the WORSE spelling: the other steps succeed, so the job — and the required
      # check — still reports green (hole #4, caught in the second review pass).
      conditions = [job["if"]] + Array(job["steps"]).grep(Hash).map { |step| step["if"] }
      conditions.any? { |condition| condition.to_s.match?(SKIP_CONTEXT_KEYS) }
    end.keys
  end

  # ---- the POSITIVE invariant's machinery --------------------------------------------

  # THE COMMAND THAT CONSTITUTES A VERDICT — pinned to the REAL suite invocation, and
  # anchored to the WHOLE LINE. If no lane runs this on a release push, the RC tip's
  # green check is backed by zero tests — and a SHA-addressed CI auditor
  # (mcritchie-studio #514) would read that empty-but-green run as a CLEAN verdict and
  # certify it.
  #
  # THE MUTATION LADDER THIS CONSTANT CLIMBED — each rung was a REAL silent false green
  # a reviewer proved against the rung below, so do not loosen it without climbing back:
  #   1. /bin\/rails\b[^\n]*\btest\b/ — a keyword sniff. `:` is a word boundary, so
  #      `\btest\b` matched inside `db:test:prepare`, and a bare `test` rode in
  #      `runner -e test …`. A prepare-only gut, and the e2e SEED step, counted as the
  #      verdict lane — so DELETING the entire rails `test` job stayed GREEN.
  #   2. `…test:system(?!\S)` — pinned, but only forbade a non-space IMMEDIATELY after.
  #      APPENDING a filter (`… test test:system -n /nothing_matches_this/`) still
  #      counted: zero tests run, guard GREEN. The flag someone adds to quiet a flaky
  #      lane sails through (Avi's catch).
  #   3. `^\s*…\s*$` — anchored BOTH ends, so the pinned command must be the ENTIRE line.
  #      This also closes two vectors the trailing anchor alone did NOT: a COMMENTED-OUT
  #      suite line (`# bin/rails db:test:prepare test test:system` — matched, ran
  #      nothing), and a SHORT-CIRCUIT prefix (`true || bin/rails …` — matched, never
  #      executed). Both were live under rung 2.
  # Each rung is pinned by a refutation fixture below (`…prepare_only…`,
  # `…runner_seed_step…`, `…appended_filter…`, `…commented_out…`, `…short_circuit…`).
  #
  # WHAT THIS PROVES — and NOTHING MORE. Read this before you widen the claim again.
  #
  # This guard was blocked FIVE times. Three of those blocks were not a missing vector but
  # an OVERCLAIM in this very comment — and every one of the three was a COUNTED, CLOSED
  # SET: "any workflow-file mutation", "the three scopes GitHub honors", "the four scopes".
  # Each number was falsified within the day. The count was always the tell: a closed-set
  # claim is a promise that nobody needs to look further, which is precisely the lie this
  # file exists to catch. **So there is no scope count here, and no closed set.**
  #
  # What ended the regress was not a sixth enumerated row. It was inverting the guard:
  #
  #   PROVEN — positively, by pinning the ONE CORRECT SHAPE rather than chasing deformations:
  #     · a lane EXISTS that runs the suite, and its `run:` script — comments and blank
  #       lines aside — is EXACTLY SUITE_SCRIPT. Not a substring, not a prefix: the whole
  #       body. This single assertion closes `export VAR=…` before the command, an inline
  #       `VAR=x cmd`, a `true ||` short-circuit, a comment-out, a heredoc `$GITHUB_ENV`
  #       write, a `cd`, a `source` — and every shell spelling nobody has imagined yet,
  #       WITHOUT predicting any of them. That is the difference between a guard and a
  #       scoreboard, and it is what this file's own header advised from version one; it
  #       took five rounds to take the advice.
  #     · that lane is UNCONDITIONAL — no job-level or step-level `if:` on the event context.
  #     · it is not neutered by `continue-on-error`, a `paths` filter, a `concurrency`
  #       group, or a dropped branch.
  #     · it is not NARROWED by an env var Rails actually reads (NARROWING_ENV_KEYS),
  #       supplied from outside the run script — the workflow `env:`, the job `env:`, the
  #       step's own `env:`, or a `$GITHUB_ENV` write from an earlier step in the same job.
  #       (The env walk earns its keep here: this is narrowing the positive invariant CANNOT
  #       see, because it arrives from outside the script body. It is stated as coverage,
  #       not as an exhaustive list of the places env can come from.)
  #
  #   NOT PROVEN — the honest edges, so nobody mistakes silence here for safety:
  #     · anything OUTSIDE this YAML. Neuter `bin/rails`, `Rakefile`, `test_helper.rb`, or
  #       a vendored gem, and the pinned command runs over an empty suite; this file reads
  #       the workflow, so it cannot see that. (A tampered-suite guard would be its own
  #       test, and a worthwhile one.)
  #     · indirection the pattern cannot follow — a composite action, a reusable workflow
  #       (`uses:`), or a `shell:` wrapper that runs the suite somewhere this file cannot
  #       read.
  #     · GitHub-side configuration: branch protection, required-check selection, a
  #       disabled workflow. Real ways to accept a green-with-no-runs tip; all live in
  #       settings, not the repo. Worth their own audit.
  #     · NARROWING_ENV_KEYS is a claim about railties 8.1.3, verified by grep at the time
  #       of writing — not a law. Re-verify it on a Rails upgrade.
  #     · the PLAYWRIGHT e2e lane is held only to EXISTENCE + UNCONDITIONALITY, not to a
  #       pinned script body: its command carries a dynamic `--shard=N/M`, so there is no
  #       single correct string to pin. The shell tricks the positive invariant kills on the
  #       rails lane (an `export` prefix, a heredoc) would therefore still work THERE. Said
  #       out loud rather than left as an inviting silence — pinning it modulo the shard
  #       interpolation is the obvious next move if the e2e verdict starts mattering as much.
  #
  # The right instinct on reading this list is NOT "the class is closed." It is "here is
  # where I would look next."
  # THE EXACT SCRIPT the suite lane must run. Not a pattern to match — the whole body.
  SUITE_SCRIPT = "bin/rails db:test:prepare test test:system"

  # Used only to FIND the lane. Whether that lane is CORRECT is decided by the positive
  # invariant below (suite_lanes_with_a_foreign_script), which compares the run body to
  # SUITE_SCRIPT exactly. A regex finds; it does not certify.
  TEST_COMMAND = /^\s*#{Regexp.escape(SUITE_SCRIPT)}\s*$/

  # Env keys that NARROW the suite to a subset (or to nothing) while the COMMAND on the
  # line stays BYTE-IDENTICAL to the real invocation. The anchored pattern above cannot
  # see any of them — only this walk can.
  #
  # VERIFIED against railties 8.1.3 (`grep -rn 'ENV\[' .../rails/test_unit/`), because
  # the first cut of this list guarded a key Rails NEVER READS (`TESTS` — zero hits in
  # the gem) while missing the live ones. A guard aimed at a dead key is decoration.
  # Re-run that grep on a Rails upgrade; this list is a claim about railties, not a
  # guess:
  #   TEST                 testing.rake:10 — `run_from_rake("test", Array(ENV["TEST"]))`.
  #                        `TEST=test/foo_test.rb` → that ONE file runs, exit 0. SILENT.
  #   TESTOPTS             runner.rb:52 — Shellwords-spliced into the spawned command.
  #                        Applies to `test:system` too (same run_from_rake path).
  #   DEFAULT_TEST         runner.rb:117 — overrides the glob `test/**/*_test.rb`.
  #   DEFAULT_TEST_EXCLUDE runner.rb:121 — excludes it. `'test/**/*_test.rb'` → 0 runs,
  #                        exit 0: a green required check over an EMPTY suite. SILENT.
  #
  # LOUD vs SILENT — measured, because it changes which payload actually threatens the RC,
  # and the obvious one is NOT the dangerous one:
  #   · `TESTOPTS='-n /nothing_matches_this/'` → 0 runs, exit **1**. LOUD: minitest fails
  #     the lane, CI goes red, everybody sees it. It is the spelling people reach for, and
  #     it is the one that cannot hurt you.
  #   · `TESTOPTS='-n /<a small PASSING subset>/'` → a couple of runs, exit **0**. SILENT.
  #     This is why TESTOPTS stays on the list — for the subset spelling, not the zero one.
  #   · `TEST=<one passing file>` → that file's runs, exit **0**. SILENT.
  #   · `DEFAULT_TEST_EXCLUDE='test/**/*_test.rb'` → 0 runs, exit **0**. SILENT, and the
  #     purest of the set: an EMPTY suite reporting success.
  # A guard tuned to the loud payload guards the one CI already catches. Tune to the quiet
  # ones. (Measured on this repo's real rake command; exact run COUNTS are deliberately not
  # pinned here — they drift with the suite and a stale number in a comment is its own
  # small lie. Re-measure, don't cite.)
  #
  # THE MECHANISM, so the next person tests the right path: the suite line is a MULTI-TASK
  # RAKE invocation (`db:test:prepare test test:system`), which routes through
  # `Rails::TestUnit::Runner.run_from_rake` — that is where TESTOPTS is spliced and where
  # the TEST/DEFAULT_TEST globs are read. The `bin/rails test <file>` COMMAND path does
  # NOT read TESTOPTS, so an experiment run that way comes back clean and the hole hides.
  NARROWING_ENV_KEYS = %w[TEST TESTOPTS DEFAULT_TEST DEFAULT_TEST_EXCLUDE].freeze

  def jobs_of(yaml_text)
    YAML.safe_load(yaml_text).fetch("jobs", {}).select { |_n, j| j.is_a?(Hash) }
  end

  def lane_label(job_name, step = nil)
    return "job `#{job_name}`" unless step

    "job `#{job_name}` → step `#{step["name"] || step["uses"] || "run"}`"
  end

  # Every [job_name, job, step] whose `run:` invokes `command`. Vector 7 (the gutted
  # command) is invisible to every blacklist in this file and lands only here.
  def command_lanes(yaml_text, command)
    jobs_of(yaml_text).flat_map do |name, job|
      Array(job["steps"]).grep(Hash)
                         .select { |step| step["run"].to_s.match?(command) }
                         .map { |step| [name, job, step] }
    end
  end

  def suite_command_lanes(yaml_text)
    command_lanes(yaml_text, TEST_COMMAND)
  end

  # ==== THE POSITIVE INVARIANT — the thing that ENDS the arms race ======================
  #
  # The suite lane's `run:` script, stripped of comments and blank lines, must be EXACTLY
  # SUITE_SCRIPT. Nothing before it, nothing after it, nothing around it.
  #
  # WHY THIS AND NOT A SIXTH BLACKLIST ROW. Five review rounds, five silent false-greens,
  # and every one had the same shape: the guard enumerated the ways the suite might be
  # neutered, and the next reviewer found a spelling one level away from wherever the last
  # one looked. `export DEFAULT_TEST_EXCLUDE=… ; bin/rails …` — no `if:`, no filter, no
  # `continue-on-error`, no `$GITHUB_ENV`, no `env:` key. Nothing for ANY blacklist bullet
  # to match, and the suite runs zero tests, exit 0, green. The `KEY<<EOF` heredoc form
  # walks past the `KEY=` regex the same way.
  #
  # There is no end to that list. There IS an end to this one: the CORRECT script has
  # exactly one shape, so pin the shape instead of chasing the deformations. An inline
  # `VAR=x cmd` prefix, a `true ||` short-circuit, a comment-out, an `export`, a heredoc,
  # a `cd`, a `source`, and every shell trick nobody has thought of yet all fail the same
  # single assertion — WITHOUT anyone predicting them. This is the advice this file's own
  # header has given since the first version ("prefer strengthening the positive
  # invariant"); it took five rounds to actually take it.
  #
  # Comments and blank lines are tolerated (they cannot execute); a trailing newline is
  # tolerated. The env walk STAYS — it catches narrowing supplied from OUTSIDE the run
  # script, which this assertion cannot see.
  def script_body(step)
    step["run"].to_s.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }
  end

  def suite_lanes_with_a_foreign_script(yaml_text)
    suite_command_lanes(yaml_text).filter_map do |name, _job, step|
      body = script_body(step)
      next if body == [ SUITE_SCRIPT ]

      "#{lane_label(name, step)} runs #{body.inspect}"
    end
  end

  # The env spelling of the narrowing attack: the suite lane's COMMAND is byte-identical
  # to the real invocation, and an env var cuts it down to a subset — or to nothing.
  #
  # ALL THREE SCOPES. The first cut of this walk read only `job["env"]` and `step["env"]`
  # — and GitHub applies a TOP-LEVEL `env:` to every step of every job, so this, sitting
  # above `jobs:`, kept the guard GREEN:
  #     env:
  #       TESTOPTS: "-n /nothing_matches_this/"
  # A guard that inspects two of the three scopes an attacker can write to is not a guard.
  #
  # PRECEDENCE (workflow → job → step, most specific wins) is honored rather than flagging
  # any mention: the level that actually SUPPLIES the value is the one reported, and a key
  # deliberately BLANKED at a more specific level (`TESTOPTS: ""`, which restores the full
  # suite) is correctly not a narrowing. A false RED here would train people to delete the
  # guard.
  # The env a step INHERITS from an earlier step in the same job. The GitHub runner exports
  # every `KEY=value` appended to the `$GITHUB_ENV` file to all SUBSEQUENT steps — a
  # DYNAMIC fourth scope that no static `env:` map in this file can see:
  #
  #     - name: Cache warm
  #       run: echo "DEFAULT_TEST_EXCLUDE=test/**/*_test.rb" >> "$GITHUB_ENV"
  #     - name: Run tests
  #       run: bin/rails db:test:prepare test test:system   # byte-identical, unconditional
  #
  # The suite step is untouched — same command, no `if:`, no env: block — and it runs ZERO
  # tests and exits 0. Only the steps ORDERED BEFORE it in the same job can reach it, so
  # that is exactly what this scans.
  def github_env_writes(job, suite_step)
    steps = Array(job["steps"]).grep(Hash)
    index = steps.index(suite_step)
    return {} if index.nil?

    steps[0...index].each_with_object({}) do |step, written|
      run = step["run"].to_s
      next unless run.include?("GITHUB_ENV")

      NARROWING_ENV_KEYS.each do |key|
        match = run.match(/(?:^|["'\s])#{Regexp.escape(key)}=([^"'\n]*)/)
        written[key] = match[1] if match
      end
    end
  end

  def narrowing_env_lanes(yaml_text)
    workflow_env = YAML.safe_load(yaml_text)["env"]

    suite_command_lanes(yaml_text).flat_map do |name, job, step|
      # PRECEDENCE, least specific → most specific:
      #   workflow `env:` < job `env:` < $GITHUB_ENV (earlier step) < the step's own `env:`
      # The most specific scope that DEFINES the key supplies the value, and that scope is
      # the one named in the finding. The blank-out exemption falls out of this for free: a
      # key set upstream but explicitly emptied on the suite step's own `env:` restores the
      # full suite, so it is correctly NOT a narrowing.
      scopes = [
        [ "workflow `env:`", workflow_env ],
        [ lane_label(name), job["env"] ],
        [ "job `#{name}` → an earlier step's $GITHUB_ENV write", github_env_writes(job, step) ],
        [ lane_label(name, step), step["env"] ]
      ]

      NARROWING_ENV_KEYS.filter_map do |key|
        label, value = scopes.reverse.filter_map { |l, env| [ l, env[key] ] if env.is_a?(Hash) && env.key?(key) }.first
        next if label.nil? || value.to_s.strip.empty?

        "#{label} (#{key})"
      end
    end.uniq
  end

  # Vector 6. `continue-on-error: true` on a job or step: it RUNS, it FAILS, it reports
  # GREEN. Checked at both levels for the same reason the `if:` walk is.
  def continue_on_error_lanes(yaml_text)
    jobs_of(yaml_text).flat_map do |name, job|
      lanes = []
      lanes << lane_label(name) if job["continue-on-error"] == true
      Array(job["steps"]).grep(Hash).each do |step|
        lanes << lane_label(name, step) if step["continue-on-error"] == true
      end
      lanes
    end
  end

  # --- [unit] trigger extraction -------------------------------------------------

  def test_unit_on_key_parses_as_boolean_true_not_the_string_on
    # Pin the trap itself. If this ever fails, Psych changed schema and the `doc["on"]`
    # fallback in push_branches is now the live path — the test still holds either way.
    doc = YAML.safe_load("on:\n  push:\n    branches: [ main ]\n")
    assert doc.key?(true), "expected Psych to parse the `on:` key as boolean true (YAML 1.1)"
    refute doc.key?("on"), "Psych now keeps `on` as a string — push_branches handles both"
  end

  def test_unit_reads_branches_from_a_flow_sequence
    assert_equal %w[main release], push_branches("on:\n  push:\n    branches: [ main, release ]\n")
  end

  def test_unit_reads_branches_from_a_block_sequence
    assert_equal %w[main release],
                 push_branches("on:\n  push:\n    branches:\n      - main\n      - release\n")
  end

  def test_unit_a_pull_request_only_workflow_has_no_push_branches
    # The release-tip blind spot, in miniature: PR-only coverage certifies no tip.
    assert_empty push_branches("on:\n  pull_request:\n")
  end

  def test_unit_detects_a_job_that_skips_itself_on_a_ref
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          if: github.ref != 'refs/heads/release'
          runs-on: ubuntu-latest
        lint:
          runs-on: ubuntu-latest
    YML
    assert_equal ["test"], jobs_skipping_release_push(yaml)
  end

  def test_unit_detects_a_job_that_skips_itself_on_the_event_name
    # THE HOLE IN THE FIRST CUT OF THIS GUARD (caught in review of mcritchie-studio
    # PR #512). This skip is the MORE natural way to write a cost saving than a
    # `github.ref` comparison, and a matcher keyed only on `github.ref` waved it
    # straight through: `release` stays in the trigger, every other assertion passes,
    # and the job runs on PRs only — so the release tip gets a green check backed by
    # zero tests.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          if: github.event_name == 'pull_request'
          runs-on: ubuntu-latest
    YML
    assert_equal ["test"], jobs_skipping_release_push(yaml)
  end

  def test_unit_detects_a_job_that_skips_itself_on_base_ref
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          if: github.base_ref == 'release'
          runs-on: ubuntu-latest
    YML
    assert_equal ["test"], jobs_skipping_release_push(yaml)
  end

  def test_unit_detects_a_step_that_skips_itself_on_the_event_name
    # THE HOLE IN THE SECOND CUT OF THIS GUARD (caught in review of mcritchie-studio
    # PR #512, second pass). Same skip as the job-level spelling, moved one level down:
    # the job carries no `if:` at all, its load-bearing step does. The step is skipped,
    # every OTHER step (checkout, setup) succeeds, and the job — and with it the
    # required check — reports GREEN having run zero tests on the release tip. A
    # matcher that reads only `job["if"]` waves it straight through.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - uses: actions/checkout@v7
            - name: Run tests
              if: github.event_name == 'pull_request'
              run: bin/rails test
    YML
    assert_equal ["test"], jobs_skipping_release_push(yaml)
  end

  def test_unit_a_step_condition_unrelated_to_the_event_context_is_not_a_skip
    # ci.yml itself carries `if: failure()` on artifact-upload steps — idiomatic,
    # and it cannot exclude a release push. Walking steps must not flag it.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Run tests
              run: bin/rails test
            - name: Keep screenshots
              if: failure()
              run: echo saved
    YML
    assert_empty jobs_skipping_release_push(yaml)
  end

  def test_unit_a_job_condition_unrelated_to_the_event_context_is_not_a_skip
    # The matcher must not flag every `if:`. A condition that does not consult the event
    # context (e.g. gating on a previous job's output) cannot exclude a release push.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          if: needs.build.outputs.changed == 'true'
          runs-on: ubuntu-latest
    YML
    assert_empty jobs_skipping_release_push(yaml)
  end

  def test_unit_detects_a_concurrency_block_at_workflow_and_job_level
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      concurrency:
        group: ci-${{ github.ref }}
        cancel-in-progress: true
      jobs:
        test:
          runs-on: ubuntu-latest
          concurrency: deploy-lock
    YML
    assert_equal %w[workflow test], concurrency_holders(yaml)
  end

  def test_unit_a_workflow_without_concurrency_has_no_holders
    assert_empty concurrency_holders("on:\n  push:\n    branches: [ main ]\njobs:\n  test:\n    runs-on: ubuntu-latest\n")
  end

  def test_unit_a_paths_filter_on_the_push_trigger_is_visible
    # A docs-only release merge commit under `paths-ignore` triggers NO workflow run at
    # all — no jobs, no checks, nothing to skip. `branches: [main, release]` is still
    # right there in the file, so every branch assertion passes while the RC tip ships
    # unverified. The filter must be absent, not merely benign-looking.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
          paths-ignore: [ 'docs/**' ]
    YML
    assert_equal ["paths-ignore"], push_trigger(yaml).keys & PATH_FILTER_KEYS
  end

  def test_unit_detects_continue_on_error_on_a_job_or_a_step
    # VECTOR 6, mutation-confirmed false-green against the blacklist alone: the suite
    # runs, the tests fail, the lane reports success. Nothing is skipped, so every `if:`
    # walk in this file sees a clean workflow.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Run tests
              continue-on-error: true
              run: bin/rails db:test:prepare test test:system
        lint:
          continue-on-error: true
          runs-on: ubuntu-latest
    YML
    assert_equal ["job `test` → step `Run tests`", "job `lint`"], continue_on_error_lanes(yaml)
  end

  def test_unit_a_gutted_suite_command_leaves_no_test_lane
    # VECTOR 7, and the reason the positive invariant exists. No `if:`, no path filter, no
    # `continue-on-error`, no concurrency group — every blacklist in this file passes this
    # workflow clean, and it runs ZERO tests on the release tip. Deleting the `test` job,
    # renaming it, or narrowing the command to one file all land in exactly this hole.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Run tests
              run: echo "suite skipped to save minutes"
    YML
    assert_empty jobs_skipping_release_push(yaml), "the blacklist sees nothing wrong here"
    assert_empty continue_on_error_lanes(yaml), "and neither does the continue-on-error walk"
    assert_empty suite_command_lanes(yaml), "but NO lane runs the suite — only this catches it"
  end

  def test_unit_a_prepare_only_command_is_not_a_test_lane
    # THE HOLE IN THE FIRST PORT OF THIS GUARD (mutation-caught in review of the
    # satellite port, task ci-on-satellite-release): `:` is a word boundary, so a
    # keyword sniff like /\btest\b/ matches INSIDE `db:test:prepare`. A step that
    # only PREPARES the test database then counts as the verdict lane, and gutting
    # the suite run to prepare-only stays GREEN — a green check over zero tests on
    # the RC tip, the exact failure this file exists to eliminate.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Prepare test DB (runs no tests)
              run: bin/rails db:test:prepare
    YML
    assert_empty suite_command_lanes(yaml),
                 "a prepare-only step runs ZERO tests — it must never count as the suite lane"
  end

  def test_unit_a_runner_seed_step_is_not_a_test_lane
    # The other spelling of the same mutation hole: an e2e SEED step carries both
    # `db:test:prepare` and a bare `test` token (`runner -e test`) while running
    # zero tests. With this step counted as a lane, DELETING the entire rails
    # `test` job kept the positive guard green.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        playwright:
          runs-on: ubuntu-latest
          steps:
            - name: Seed test DB
              run: bin/rails db:test:prepare && bin/rails runner -e test e2e/seed.rb
    YML
    assert_empty suite_command_lanes(yaml),
                 "a seed/runner step runs ZERO tests — it must never count as the suite lane"
  end

  def test_unit_an_appended_filter_flag_is_not_a_test_lane
    # THE HOLE IN THE PINNED PATTERN'S FIRST CUT (Avi's catch): `(?!\S)` only forbids a
    # non-space IMMEDIATELY after `test:system`, so APPENDING a narrowing flag left the
    # lane counted and the guard GREEN. `-n /nothing_matches_this/` runs ZERO tests while
    # the command still reads like the real suite — precisely what someone reaches for to
    # quiet a flaky lane "temporarily". The command must be the WHOLE trailing command on
    # its line (`\s*$`), not merely a prefix of one.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Run tests
              run: bin/rails db:test:prepare test test:system -n /nothing_matches_this/
    YML
    assert_empty suite_command_lanes(yaml),
                 "a narrowed suite command runs ~zero tests — it must never count as the suite lane"
  end

  def test_unit_a_commented_out_suite_command_is_not_a_test_lane
    # Live under the trailing-anchor-only pattern: the line still ENDS in `test:system`,
    # so it matched — while running nothing at all. Anchoring the START is what kills it.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Run tests
              run: |
                # bin/rails db:test:prepare test test:system
                echo "suite temporarily disabled"
    YML
    assert_empty suite_command_lanes(yaml),
                 "a commented-out suite command runs ZERO tests — it must never count as the suite lane"
  end

  def test_unit_a_short_circuited_suite_command_is_not_a_test_lane
    # The other one the trailing anchor missed: the line ends in `test:system`, but the
    # shell never reaches it (`true ||` short-circuits). Matched, executed nothing.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Run tests
              run: |
                true || bin/rails db:test:prepare test test:system
    YML
    assert_empty suite_command_lanes(yaml),
                 "a short-circuited suite command never executes — it must never count as the suite lane"
  end

  def test_unit_detects_a_narrowing_TESTOPTS_env_on_the_suite_lane
    # The env spelling of the appended filter: the command is byte-identical to the real
    # suite invocation (so TEST_COMMAND matches, correctly), and TESTOPTS cuts it to zero
    # tests. The pattern alone cannot see this — only the env walk does.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Run tests
              env:
                TESTOPTS: "-n /nothing_matches_this/"
              run: bin/rails db:test:prepare test test:system
    YML
    refute_empty suite_command_lanes(yaml), "the command itself still reads as the suite lane"
    assert_equal ["job `test` → step `Run tests` (TESTOPTS)"], narrowing_env_lanes(yaml)
  end

  def test_unit_the_real_suite_lane_carries_no_narrowing_env
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Run tests
              env:
                RAILS_ENV: test
              run: bin/rails db:test:prepare test test:system
    YML
    assert_empty narrowing_env_lanes(yaml), "an ordinary RAILS_ENV must not be flagged as narrowing"
  end

  def test_unit_detects_a_WORKFLOW_LEVEL_env_narrowing_the_suite
    # THE HOLE IN THE ENV WALK'S FIRST CUT: it read job["env"] and step["env"] only.
    # GitHub applies a TOP-LEVEL `env:` to every step of every job, and the real suite step
    # sets no TESTOPTS to shadow it — so this kept the guard GREEN while the suite ran
    # zero tests. Two of three scopes is not a guard.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      env:
        TESTOPTS: "-n /nothing_matches_this/"
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Run tests
              run: bin/rails db:test:prepare test test:system
    YML
    assert_equal [ "workflow `env:` (TESTOPTS)" ], narrowing_env_lanes(yaml)
  end

  def test_unit_detects_a_TEST_env_narrowing_the_suite_to_one_file
    # `TEST` (singular) is the key railties ACTUALLY reads — testing.rake:10,
    # `run_from_rake("test", Array(ENV["TEST"]))`. The first cut of NARROWING_ENV_KEYS
    # guarded `TESTS` (plural), which railties never reads: a guard pointed at a dead key,
    # while `TEST: test/one_trivial_test.rb` sailed through — the full suite collapses to
    # that one file's runs, exit 0, GREEN (measured on this repo's real rake command).
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Run tests
              env:
                TEST: test/models/one_trivial_test.rb
              run: bin/rails db:test:prepare test test:system
    YML
    assert_equal [ "job `test` → step `Run tests` (TEST)" ], narrowing_env_lanes(yaml)
  end

  def test_unit_detects_the_glob_override_keys
    # DEFAULT_TEST (runner.rb:117) overrides the test glob; DEFAULT_TEST_EXCLUDE
    # (runner.rb:121) excludes it. Measured: DEFAULT_TEST_EXCLUDE='test/**/*_test.rb' →
    # 0 runs, exit 0, GREEN — a green required check over an EMPTY suite.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Run tests
              env:
                DEFAULT_TEST_EXCLUDE: "test/**/*_test.rb"
              run: bin/rails db:test:prepare test test:system
    YML
    assert_equal [ "job `test` → step `Run tests` (DEFAULT_TEST_EXCLUDE)" ], narrowing_env_lanes(yaml)
  end

  # --- [unit] the POSITIVE invariant: the run script is EXACTLY the pinned command ------
  #
  # ONE assertion, and every shell spelling below fails it — including the two that
  # defeated the blacklist (`export` prefix, heredoc) and every one nobody has imagined.
  # No new bullet was added for any of them.

  def test_unit_an_export_prefix_in_the_run_script_is_a_foreign_script
    # THE FIFTH SILENT FALSE-GREEN, and the one that proved the blacklist could never end:
    # no `if:`, no `continue-on-error`, no path filter, no `$GITHUB_ENV`, no `env:` key —
    # nothing for ANY enumerated bullet to match. The suite command is byte-identical and
    # unconditional. It runs ZERO tests, exit 0, GREEN.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Run tests
              run: |
                export DEFAULT_TEST_EXCLUDE='test/**/*_test.rb'
                bin/rails db:test:prepare test test:system
    YML
    refute_empty suite_command_lanes(yaml), "the lane is still FOUND — the command line is intact"
    assert_empty narrowing_env_lanes(yaml), "and the env walk sees nothing: it is not an env: key"
    refute_empty suite_lanes_with_a_foreign_script(yaml), "ONLY the positive invariant catches it"
  end

  def test_unit_an_inline_variable_prefix_is_never_a_valid_suite_lane
    # `VAR=x cmd` — same neutering, no `export`, nothing for a blacklist to match. Here the
    # lane is not even FOUND (the command is no longer the whole line), so the PRIMARY
    # guard's `refute_empty` is what fires. Two independent assertions have to agree that
    # this workflow has no valid suite lane, and both do.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Run tests
              run: DEFAULT_TEST_EXCLUDE='test/**/*_test.rb' bin/rails db:test:prepare test test:system
    YML
    assert_empty suite_command_lanes(yaml),
                 "an inline VAR=x prefix leaves NO lane running the pinned script — the primary " \
                 "guard's refute_empty fails, which is the RED we want"
  end

  def test_unit_a_heredoc_GITHUB_ENV_write_in_the_run_script_is_a_foreign_script
    # GitHub's DOCUMENTED multiline form: `KEY<<EOF`. The $GITHUB_ENV walk keys on `KEY=`,
    # so the heredoc spelling walks straight past it — a blacklist chasing a syntax. The
    # positive invariant does not care HOW the extra lines are spelled: they are extra.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Run tests
              run: |
                cat >> "$GITHUB_ENV" <<EOF
                DEFAULT_TEST_EXCLUDE<<HEREDOC
                test/**/*_test.rb
                HEREDOC
                EOF
                bin/rails db:test:prepare test test:system
    YML
    refute_empty suite_lanes_with_a_foreign_script(yaml),
                 "the heredoc form must not walk past the guard the way it walks past a `KEY=` regex"
  end

  def test_unit_a_short_circuit_or_comment_in_the_run_script_is_a_foreign_script
    # The blacklist already caught these two by ANCHORING; the positive invariant catches
    # them again, for free, from the other direction. Belt and braces on the worst vectors.
    short_circuit = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Run tests
              run: |
                true || bin/rails db:test:prepare test test:system
    YML
    assert_empty suite_command_lanes(short_circuit), "not even found as a lane — refute_empty fails first"
  end

  def test_unit_the_intact_script_passes_with_comments_blank_lines_and_a_trailing_newline
    # THE OTHER HALF, and the one that matters most: the invariant must not FALSE-RED on
    # the real thing. Comments and blank lines cannot execute, so they are tolerated; a
    # trailing newline is tolerated. If this ever fails, the guard starts crying wolf —
    # and a guard that cries wolf is a guard someone deletes.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Run tests
              run: |
                # The whole suite, unconditionally. See test/lib/ci_workflow_triggers_test.rb.

                bin/rails db:test:prepare test test:system
    YML
    assert_empty suite_lanes_with_a_foreign_script(yaml)
    refute_empty suite_command_lanes(yaml)
  end

  def test_unit_detects_a_GITHUB_ENV_write_from_an_EARLIER_step
    # THE FOURTH SCOPE — and the hole in the env walk's second cut, which read the three
    # STATIC `env:` maps and declared the class closed. The runner exports anything an
    # earlier step appends to $GITHUB_ENV to every SUBSEQUENT step, so the suite step is
    # narrowed without a single character of it changing: same command, no `if:`, no env:.
    # Demonstrated GREEN against the previous guard while the suite ran 0 tests, exit 0.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Cache warm
              run: echo "DEFAULT_TEST_EXCLUDE=test/**/*_test.rb" >> "$GITHUB_ENV"
            - name: Run tests
              run: bin/rails db:test:prepare test test:system
    YML
    assert_equal [ "job `test` → an earlier step's $GITHUB_ENV write (DEFAULT_TEST_EXCLUDE)" ],
                 narrowing_env_lanes(yaml)
  end

  def test_unit_a_GITHUB_ENV_write_AFTER_the_suite_step_is_not_a_narrowing
    # Ordering is the whole mechanism: $GITHUB_ENV reaches only SUBSEQUENT steps. A write
    # that lands after the suite has already run cannot narrow it, and flagging it would be
    # a false red.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Run tests
              run: bin/rails db:test:prepare test test:system
            - name: Hand off to the next job
              run: echo "DEFAULT_TEST_EXCLUDE=test/**/*_test.rb" >> "$GITHUB_ENV"
    YML
    assert_empty narrowing_env_lanes(yaml)
  end

  def test_unit_the_suite_steps_own_env_blanks_out_an_earlier_GITHUB_ENV_write
    # Precedence across the new scope: `step env:` outranks $GITHUB_ENV, so an upstream
    # write explicitly emptied on the suite step restores the full suite — not a narrowing.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Cache warm
              run: echo "DEFAULT_TEST_EXCLUDE=test/**/*_test.rb" >> "$GITHUB_ENV"
            - name: Run tests
              env:
                DEFAULT_TEST_EXCLUDE: ""
              run: bin/rails db:test:prepare test test:system
    YML
    assert_empty narrowing_env_lanes(yaml)
  end

  def test_unit_an_ordinary_GITHUB_ENV_write_is_not_flagged
    # The walk must not flag every $GITHUB_ENV write — only one carrying a key Rails reads.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Record the SHA
              run: echo "BUILD_SHA=$GITHUB_SHA" >> "$GITHUB_ENV"
            - name: Run tests
              run: bin/rails db:test:prepare test test:system
    YML
    assert_empty narrowing_env_lanes(yaml)
  end

  def test_unit_a_more_specific_scope_blanking_the_key_is_not_a_narrowing
    # Precedence, not mere mention: a workflow-level TESTOPTS explicitly BLANKED on the
    # suite step restores the full suite. Flagging it would be a FALSE RED — and a guard
    # that cries wolf is a guard people delete.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      env:
        TESTOPTS: "-n /nothing/"
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Run tests
              env:
                TESTOPTS: ""
              run: bin/rails db:test:prepare test test:system
    YML
    assert_empty narrowing_env_lanes(yaml)
  end

  def test_unit_recognizes_the_real_suite_command_as_a_test_lane
    # The other half of vector 7: TEST_COMMAND must actually MATCH the live command, or
    # the positive guard asserts a lane that never existed and passes vacuously — the
    # same failure mode as the `on:`-boolean trap at the top of this file.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Run tests
              run: bin/rails db:test:prepare test test:system
    YML
    lanes = suite_command_lanes(yaml)

    assert_equal 1, lanes.size
    assert_equal "test", lanes.first[0]
  end

  # --- [integration] the real committed workflow ----------------------------------

  # ==== THE PRIMARY GUARD =============================================================
  # Positive, not a blacklist. Every other integration assertion in this file enumerates
  # a way the suite might NOT run; this one asserts that it DOES. On the lane that IS the
  # verdict, ANY condition fails — not merely the three `github.*` spellings a reviewer
  # happened to show me. That is the difference between a guard and a scoreboard.
  def test_integration_the_suite_runs_UNCONDITIONALLY_on_a_release_push
    lanes = suite_command_lanes(File.read(CI_YML))

    refute_empty lanes,
                 "NO step in ci.yml runs a command matching #{TEST_COMMAND.source}. A " \
                 "release push would produce GREEN checks having executed zero tests — " \
                 "and a SHA-addressed CI auditor would read that empty-but-green run " \
                 "as a clean verdict and certify an RC that CI never tested. A false RED " \
                 "wastes a day; a false GREEN ships. If the suite legitimately moved or " \
                 "the command changed, re-point TEST_COMMAND at it — do not delete this."

    lanes.each do |job_name, job, step|
      assert_nil job["if"],
                 "#{lane_label(job_name)} runs the suite but carries `if: #{job["if"]}`. " \
                 "The lane that IS the verdict must be UNCONDITIONAL on a release push. " \
                 "Any condition — event context, env var, workflow input, matrix flag — " \
                 "can silently exclude the RC tip. Prove it still runs on a push to " \
                 "refs/heads/release, then update this test deliberately."
      assert_nil step["if"],
                 "#{lane_label(job_name, step)} runs the suite but carries " \
                 "`if: #{step["if"]}`. A skipped STEP leaves the JOB REPORTING SUCCESS — " \
                 "a green required check over zero tests, invisible in the check " \
                 "conclusion and indistinguishable from a real pass to any auditor " \
                 "reading it by SHA. This is the worst failure mode in the file."
    end
  end

  def test_integration_the_suite_run_script_is_EXACTLY_the_pinned_command
    foreign = suite_lanes_with_a_foreign_script(File.read(CI_YML))

    assert_empty foreign,
                 "#{foreign.inspect} — the suite lane's `run:` script must be EXACTLY " \
                 "#{SUITE_SCRIPT.inspect} (comments and blank lines aside). Anything else in " \
                 "that script can neuter the suite while every other assertion in this file " \
                 "passes: `export DEFAULT_TEST_EXCLUDE=…` before it, an inline `VAR=x` prefix, " \
                 "a `true ||` short-circuit, a heredoc write to $GITHUB_ENV — all of them ran " \
                 "ZERO tests and reported GREEN against earlier versions of this guard. This is " \
                 "the POSITIVE invariant: it does not enumerate the attacks, it pins the one " \
                 "correct shape. If the suite command legitimately changes, change SUITE_SCRIPT " \
                 "deliberately — do not relax this into a substring match."
  end

  def test_integration_the_suite_lane_is_not_narrowed_by_env
    lanes = narrowing_env_lanes(File.read(CI_YML))

    assert_empty lanes,
                 "#{lanes.inspect} set #{NARROWING_ENV_KEYS.join("/")} on the lane that IS the " \
                 "verdict — the command still reads as the full suite while running a subset (or " \
                 "nothing). Same lie as an appended `-n` filter, spelled in the environment."
  end

  def test_integration_no_lane_reports_green_over_failing_tests
    lanes = continue_on_error_lanes(File.read(CI_YML))

    assert_empty lanes,
                 "#{lanes.inspect} set `continue-on-error: true` — the lane RUNS, the " \
                 "tests FAIL, and it reports GREEN anyway. Zero-tests-green and " \
                 "failing-tests-green are the same lie told to the release candidate."
  end

  # turf-monster only: the sharded Playwright e2e suite is part of THIS repo's RC
  # verdict, so it gets the same positive invariant as the rails suite — some step
  # must actually run it, unconditionally. (The `if:` walk and the continue-on-error
  # walk above already cover its steps; this closes the delete-the-job /
  # gut-the-command class for the e2e lane too.)
  E2E_COMMAND = /\bnpm test\b/

  def test_integration_the_e2e_lane_runs_UNCONDITIONALLY_on_a_release_push
    lanes = command_lanes(File.read(CI_YML), E2E_COMMAND)

    refute_empty lanes,
                 "NO step in ci.yml runs a command matching #{E2E_COMMAND.source}. The " \
                 "Playwright suite is part of this repo's release-push verdict — if the " \
                 "e2e runner legitimately changed, re-point E2E_COMMAND at it; do not " \
                 "delete this."

    lanes.each do |job_name, job, step|
      assert_nil job["if"],
                 "#{lane_label(job_name)} runs the e2e suite but carries `if: #{job["if"]}` — " \
                 "the e2e lane must be UNCONDITIONAL on a release push."
      assert_nil step["if"],
                 "#{lane_label(job_name, step)} runs the e2e suite but carries " \
                 "`if: #{step["if"]}` — a skipped step leaves the job reporting success " \
                 "over zero e2e tests."
    end
  end
  # ====================================================================================

  def test_integration_ci_runs_on_pushes_to_every_rung_of_the_ladder
    branches = push_branches(File.read(CI_YML))

    assert_includes branches, "main",
                    "ci.yml must run on pushes to main — the shipped tip"
    assert_includes branches, "release",
                    "ci.yml must run on pushes to release. The sweep's merge commit is the " \
                    "artifact QA deploys and ship fast-forwards; without this trigger it is " \
                    "the one commit CI never runs, leaving the local G3 gate as its only verdict."
    # `accepted` was missing here until 2026-08-18, and its absence did more than skip a
    # build: it DISARMED A GUARD. bin/release prepare refuses to promote a RED `accepted`
    # (refuse_red_accepted!), and with no run on this branch that verdict read :none —
    # which deliberately does not block, so the guard passed over this repo in every
    # release without ever having been capable of failing.
    assert_includes branches, "accepted",
                    "ci.yml must run on pushes to accepted. Review merges several approved PRs " \
                    "onto it, producing a combination no CI run has executed — the same argument " \
                    "that puts `release` here, one rung earlier and one rung cheaper to unwind. " \
                    "Drop this trigger and bin/release prepare's accepted guard silently loses " \
                    "the ability to fail at all."
  end

  def test_integration_ci_still_runs_on_pull_requests
    assert triggers(File.read(CI_YML)).key?("pull_request"),
           "adding the release push trigger must not displace per-PR coverage"
  end

  def test_integration_no_job_opts_out_of_the_release_push_verdict
    skipped = jobs_skipping_release_push(File.read(CI_YML))

    assert_empty skipped,
                 "job(s) #{skipped.inspect} carry a github event-context condition " \
                 "(#{SKIP_CONTEXT_KEYS.source}) on the job or on one of its steps. The " \
                 "release candidate earns a FULL verdict — no lane may be skipped on a " \
                 "release push for cost, whether spelled as a ref comparison, an " \
                 "event_name check, or a base_ref check, at the JOB or at the STEP " \
                 "level (a skipped step is the worse spelling: the job still reports " \
                 "green). If such a condition is genuinely needed, prove the tests " \
                 "still RUN on a push to refs/heads/release and update this test " \
                 "deliberately."
  end

  def test_integration_no_concurrency_block_can_cancel_a_release_run
    holders = concurrency_holders(File.read(CI_YML))

    assert_empty holders,
                 "#{holders.inspect} carry a `concurrency:` block. Back-to-back release " \
                 "pushes are NORMAL (sweep merge, then re-pin): a concurrency group lets " \
                 "the second push cancel or supersede the first SHA's run, and a " \
                 "`cancelled` conclusion reads as RED to a SHA-addressed CI auditor — a " \
                 "false alarm on a healthy release candidate. Every release SHA keeps " \
                 "its own run to completion."
  end

  def test_integration_no_path_filter_strands_the_release_tip
    filters = push_trigger(File.read(CI_YML)).keys & PATH_FILTER_KEYS

    assert_empty filters,
                 "the push trigger carries #{filters.inspect}. A path filter suppresses " \
                 "the workflow RUN, not just a job — a docs-only merge commit on release " \
                 "would get NO CI verdict at all while `branches: [main, release]` still " \
                 "reads correct. Every release tip is shipped; every release tip is run."
  end
end
