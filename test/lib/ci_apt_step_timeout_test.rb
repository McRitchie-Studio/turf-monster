# frozen_string_literal: true

# Guard: every apt fetch in CI is BOUNDED AT THE STEP and RETRIES.
#
# PORTED FROM mcritchie-studio (PR #939, /tasks/bound-and-retry-apt-fetches). Kept
# deliberately close to the original so the two repos read as one shape; if you
# change the contract here, change it there in the same pass.
#
# THIS REPO HAD THE ORDERING BUG TOO. `Install packages` ran at step 0, BEFORE
# actions/checkout — which an inline `run:` can survive and a script invocation
# cannot. Found by the guard below before it ever reached CI, which is exactly the
# saving the hub did not get: it shipped that ordering and lost four jobs to it.
#
# test/lib/ci_job_timeout_test.rb is the sibling of this file and bounds the JOB.
# Read them together; they are the same incident at two grains, and the distinction
# is the entire reason this file exists.
#
# WHAT THE JOB-LEVEL BOUND ALREADY DID. `timeout-minutes: 45` on every job replaced
# GitHub's six-hour default, which is why a stalled fetch dies in 45 minutes instead
# of running until someone cancels it by hand. That mattered: a hung run cannot be
# `gh run rerun`, so before it, a stall blocked the retry as well as the run.
#
# WHAT IT COULD NOT DO. It turns "hangs forever" into "fails", and stops there. On
# 2026-08-19 that was not enough — the same fetch stalled FIVE times across five PRs,
# every one on the same line:
#
#   Get:5 https://archive.ubuntu.com/ubuntu noble-security InRelease [126 kB]
#   ...42 minutes of total silence...
#   ##[error]The operation was canceled.
#
# Five green branches went red, each costing ~45 minutes of runner time per affected
# job plus a human to work out that nothing was wrong with the code. Bounding the
# FETCH and retrying turns that into "recovers in 90 seconds" — measured live on the
# very first run carrying the fix, PR #939's island_animator: attempt 1 killed at
# 90s, attempt 2 succeeded at 277s, job green in 6m07s where the unfixed branch took
# 25m00s for the same step against the same mirror.
#
# WHY THIS TEST RUNS THE REAL SCRIPT RATHER THAN GREPPING FOR IT. A guard that only
# asserts `timeout-minutes` is present cannot tell a loop that retries from a loop
# that runs once, and the retry is the half that does the work. So the behavioural
# tests EXECUTE .github/scripts/apt-retry — the actual file CI runs, unmodified —
# against a stubbed apt-get that stalls on command. Two things are faked, and
# nothing else:
#
#   * the BUDGETS, via the script's own APT_RETRY_BUDGETS override, so the suite
#     takes a second instead of 22 minutes. Nothing in CI sets it, and the default
#     is asserted below, so the override cannot quietly become the shipped bound.
#   * `timeout` ITSELF, which is GNU coreutils and absent from a developer Mac.
#     Faking it is what lets this file run everywhere instead of skipping into
#     decoration on half the machines that matter — and the stub RECORDS its
#     arguments, so deleting `timeout -k 10` from the script is caught by the
#     assertion that it was invoked, not merely by the loop misbehaving.
require "minitest/autorun"
require "yaml"
require "tmpdir"
require "fileutils"

class CiAptStepTimeoutTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  WORKFLOW_GLOB = File.join(ROOT, ".github/workflows/*.yml")
  SCRIPT = File.join(ROOT, ".github/scripts/apt-retry")

  # A step bound is only meaningful below the 45-minute JOB bound it sits under. 25
  # sits above the script's own ~22-minute worst case and well below 45.
  STEP_CEILING = 30

  # The harness's own deadline. Every scenario is engineered to finish in about a
  # second; anything near this means the script stopped honouring its bound, which
  # is the defect under guard. Enforced in Ruby because the machine may have no
  # `timeout` to enforce it with.
  HARNESS_DEADLINE = 45

  def apt_steps
    paths = Dir[WORKFLOW_GLOB].sort
    refute_empty paths, "no workflows at #{WORKFLOW_GLOB} — this guard is looking in the wrong place"

    paths.flat_map do |path|
      jobs = (YAML.load_file(path, aliases: true) || {})["jobs"] || {}
      jobs.flat_map do |job_name, job|
        next [] unless job.is_a?(Hash)

        Array(job["steps"]).select { |s| s.is_a?(Hash) && s["run"].to_s.include?("apt") }
                           .map { |s| { file: File.basename(path), job: job_name, step: s } }
      end
    end
  end

  # ---- the drift guards -----------------------------------------------------

  def test_every_apt_step_declares_its_own_bound
    steps = apt_steps

    # Vacuity guard: green must mean "every fetch checked", never "no fetches found".
    assert_operator steps.length, :>=, 1,
                    "expected this repo's apt step (the `test` job's Install packages); found " \
                    "#{steps.length}. If the fetch moved, follow it here — do not delete the guard."

    unbounded = steps.reject { |s| s[:step]["timeout-minutes"] }
                     .map { |s| "#{s[:file]} :: #{s[:job]} :: #{s[:step]['name']}" }
    assert_empty unbounded,
                 "these apt steps carry no step-level `timeout-minutes`, so a stalled mirror runs until " \
                 "the 45-minute JOB bound kills the whole job — unrecoverably, with no retry:\n  " +
                 unbounded.join("\n  ")

    too_large = steps.select { |s| s[:step]["timeout-minutes"].to_i > STEP_CEILING }
                     .map { |s| "#{s[:job]} :: #{s[:step]['name']} (#{s[:step]['timeout-minutes']}m)" }
    assert_empty too_large,
                 "a step bound above #{STEP_CEILING}m is not distinguishable from the 45m job bound it " \
                 "sits under, so it buys nothing:\n  " + too_large.join("\n  ")
  end

  def test_the_retry_loop_stays_out_of_the_workflow
    # THE REGRESSION THIS CATCHES, which is not hypothetical — it shipped, went red
    # in CI, and is why the script exists. The loop was inline in ci.yml first, as
    # `if sudo timeout -k 10 "$budget" bash -c '...'`. That hands an interpolated
    # token to a command position, and bin/lib/ci_test_command.rb — the cert that
    # reads ci.yml to prove it can SEE every unit CI runs — correctly REFUSED to
    # claim it knew what the step ran. Three tests in
    # test/lib/ci_test_command_test.rb went red, including the one asserting the hub
    # has no unit the cert is blind to.
    #
    # The parser is right and cannot be relaxed for this: its exception list is keyed
    # on executables PROVEN to exec nothing, and `timeout` execs an argument by
    # definition — putting it on that list would blind the cert to `timeout 300
    # $SUITE`. So the invariant is the other way round: the workflow step stays a
    # literal, readable invocation, and anything with a variable in it lives in the
    # script. Inline it again and this fails BEFORE CI does.
    inlined = apt_steps.select { |s| s[:step]["run"].to_s.match?(/for budget|\$\{?budget/) }
                       .map { |s| "#{s[:job]} :: #{s[:step]['name']}" }

    assert_empty inlined,
                 "these steps inline the retry loop instead of calling .github/scripts/apt-retry. An " \
                 "interpolated token in a command position makes the step OPAQUE to " \
                 "bin/lib/ci_test_command.rb and reddens test/lib/ci_test_command_test.rb:\n  " +
                 inlined.join("\n  ")

    not_calling = apt_steps.reject { |s| s[:step]["run"].to_s.include?(".github/scripts/apt-retry") }
                           .map { |s| "#{s[:job]} :: #{s[:step]['name']}" }
    assert_empty not_calling,
                 "every apt fetch must go through .github/scripts/apt-retry, or it is unbounded and " \
                 "unretried no matter what `timeout-minutes` says:\n  " + not_calling.join("\n  ")
  end

  def test_the_checkout_precedes_every_fetch
    # THE REGRESSION THIS CATCHES, which also shipped and also went red. Moving the
    # loop into a script made the workflow legible again — and instantly broke the
    # `test` and `playwright` jobs, because in BOTH of them `Install packages` was
    # the FIRST step in the job, running BEFORE `actions/checkout`. An inline `run:`
    # block needs nothing from the repo; a script invocation needs the repo to exist.
    # So all four jobs died in ~30 seconds on "No such file or directory".
    #
    # island_animator is why the cause was findable in one look: it checks out FIRST,
    # so it passed on the very same commit that failed everywhere else — the one job
    # whose order was already right.
    #
    # This is not a stylistic preference about step order. It is the precondition the
    # script form introduced, and nothing else in the file states it.
    offenders = []

    Dir[WORKFLOW_GLOB].sort.each do |path|
      jobs = (YAML.load_file(path, aliases: true) || {})["jobs"] || {}
      jobs.each do |job_name, job|
        next unless job.is_a?(Hash)

        names = Array(job["steps"]).map { |s| s.is_a?(Hash) ? "#{s['name']} #{s['uses']} #{s['run']}" : "" }
        fetch = names.index { |n| n.include?("apt-retry") }
        next if fetch.nil?

        checkout = names.index { |n| n.include?("actions/checkout") }
        offenders << "#{File.basename(path)} :: #{job_name} (checkout=#{checkout.inspect}, fetch=#{fetch})" if checkout.nil? || checkout > fetch
      end
    end

    assert_empty offenders,
                 "these jobs run .github/scripts/apt-retry BEFORE checking the repo out, so the script " \
                 "does not exist yet and the step dies instantly on 'No such file or directory':\n  " +
                 offenders.join("\n  ")
  end

  def test_the_script_is_committed_executable
    assert File.exist?(SCRIPT), "#{SCRIPT} is missing — every apt step invokes it"
    assert File.executable?(SCRIPT),
           "#{SCRIPT} is not executable. `run: .github/scripts/apt-retry …` execs it directly, so a " \
           "lost mode bit fails EVERY job at its first step — commit it 100755."
  end

  def test_the_script_delegates_its_bound_to_timeout
    # COMMENTS STRIPPED FIRST, and that is not fussiness. This script DOCUMENTS its
    # own shape — one comment line explains the defect by quoting `if sudo timeout
    # -k 10 "$budget" ...` as prose. Matching the raw file therefore matched the
    # COMMENT: in mcritchie-industries, which ports these drift guards without the
    # behavioural ones below, a mutation deleting the real `timeout` wrapper from the
    # code left this assertion GREEN. Measured, not theorised. Assert against what
    # the shell will execute, never against what the file says about itself.
    body = File.read(SCRIPT).lines.reject { |l| l.strip.start_with?("#") }.join

    assert_match(/timeout\s+-k\s+\d+\s+"\$budget"/, body,
                 "`timeout-minutes` alone only kills the STEP — it cannot retry. Without `timeout -k " \
                 "<n> \"$budget\"` wrapping the fetch, there is nothing to retry after.")

    assert_match(/APT_RETRY_BUDGETS:=90 300 900/, body,
                 "the shipped budgets must stay 90/300/900. Measured over 40 samples of successful " \
                 "runs: healthy is 10-16s, but the SUCCESS tail runs 318s, 560s, 812s, 857s — a flat " \
                 "short bound kills passing steps, and a flat long one never retries in time. PR #939 " \
                 "proved it live: attempt 1 killed at 90s, attempt 2 succeeded at 277s.")
  end

  # ---- the behavioural guards, running the real script ----------------------

  def test_a_persistent_stall_is_killed_retried_and_fails
    result = run_script(mode: "stall")

    refute_equal 0, result[:status],
                 "a mirror that never responds must FAIL the step. It exited 0, so CI would proceed " \
                 "without the packages installed."

    assert_equal 3, result[:apt_calls],
                 "expected exactly 3 attempts against the stalling mirror, saw #{result[:apt_calls]}. " \
                 "One attempt means the retry is gone; more than three means the loop lost its bound."

    assert_equal 3, result[:timeout_calls].length,
                 "the fetch must be wrapped in `timeout` on EVERY attempt, not just the first"

    assert(result[:timeout_calls].all? { |c| c.start_with?("-k 10 ") },
           "every attempt must pass `-k 10`: timeout sends SIGTERM first, and a wedged apt need not " \
           "honour it — an attempt that ignores its own bound defeats the step. Saw: #{result[:timeout_calls].inspect}")

    assert_equal 3, result[:dpkg_calls],
                 "each killed attempt must run `dpkg --configure -a` before the next, or an attempt " \
                 "killed mid-unpack fails the following one for a reason unrelated to the network"

    assert_includes result[:output], "::error::",
                    "a fully-failed fetch must annotate the run, so the cause reads off the checks " \
                    "page instead of out of a 40-minute log"
  end

  def test_a_transient_stall_recovers_on_a_later_attempt
    # Stalls attempts 1 and 2, answers on 3 — the shape of the real incident. This
    # is the case the whole change exists to convert from a red PR into a non-event.
    result = run_script(mode: "flaky", ok_on: 3)

    assert_equal 0, result[:status],
                 "a mirror that answers on the third attempt must PASS. It failed, which means the " \
                 "retry is not actually recovering — the reds this change removes would still land.\n" +
                 result[:output]

    assert_includes result[:output], "::notice::",
                    "a recovered fetch should say so, so a slow run is legible without reading the log"
  end

  def test_a_healthy_mirror_costs_exactly_one_attempt
    result = run_script(mode: "healthy")

    assert_equal 0, result[:status], "a healthy fetch must pass:\n#{result[:output]}"

    # update + install, once each. The ordinary case measured 10-16 seconds; a retry
    # loop that re-runs a SUCCEEDING fetch would triple every CI run.
    assert_equal 2, result[:apt_calls],
                 "a healthy mirror must be hit exactly twice (update, install), not #{result[:apt_calls]}"

    refute_includes result[:output], "::warning::",
                    "a healthy fetch must not warn — a step that cries wolf on every green run trains " \
                    "everyone to ignore it on the red one"
  end

  def test_it_refuses_to_run_with_no_packages
    result = run_script(mode: "healthy", packages: [])

    refute_equal 0, result[:status],
                 "called with no packages the script must refuse, not silently 'succeed' at installing " \
                 "nothing — that would let a step lose its package list and still go green"
    assert_equal 0, result[:apt_calls], "it must not reach apt at all with an empty package list"
  end

  private

  # Executes .github/scripts/apt-retry — the real file, unmodified — against stubs.
  def run_script(mode:, ok_on: 1, packages: [ "ffmpeg" ])
    Dir.mktmpdir("apt-retry") do |dir|
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)
      apt_count   = File.join(dir, "apt.count")
      timeout_log = File.join(dir, "timeout.log")
      dpkg_count  = File.join(dir, "dpkg.count")

      # sudo: run the command, nothing more. The real one adds privilege; the
      # script's behaviour does not depend on having it.
      write_stub File.join(bin, "sudo"), <<~SH
        exec "$@"
      SH

      # timeout: faithful enough to bound a child, and it RECORDS its arguments so
      # the test can prove the script still delegates to it.
      write_stub File.join(bin, "timeout"), <<~SH
        echo "$*" >> "#{timeout_log}"
        k=0
        if [ "$1" = "-k" ]; then k="$2"; shift 2; fi
        budget="$1"; shift
        "$@" &
        child=$!
        # Detached from the harness's pipe on purpose: this subshell sleeps out the
        # `-k` grace period AFTER killing the child, so it outlives the attempt.
        ( sleep "$budget"; kill -TERM "$child" 2>/dev/null; sleep "$k"; kill -KILL "$child" 2>/dev/null ) \\
          >/dev/null 2>&1 </dev/null &
        watcher=$!
        wait "$child"; rc=$?
        kill "$watcher" 2>/dev/null
        # GNU timeout reports 124 on expiry; a killed child surfaces as 128+n.
        [ "$rc" -ge 128 ] && rc=124
        exit "$rc"
      SH

      # apt-get: stalls or answers on command, and counts how often it was asked.
      write_stub File.join(bin, "apt-get"), <<~SH
        n=$(( $(cat "#{apt_count}" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "#{apt_count}"
        case "#{mode}" in
          healthy) exit 0 ;;
          flaky)   [ "$n" -ge "#{ok_on}" ] && exit 0 ;;
        esac
        # The stall. `exec` AND the redirects both matter: REAL GNU timeout runs its
        # command in a new PROCESS GROUP and signals the group, so in CI this dies
        # with the shell above it. The stub above is simpler and signals only its
        # direct child, so without `exec` a stub shell survives here holding the
        # harness's output pipe and the reader blocks on it — measured at 34s and 32s
        # per stalling scenario before this line was right.
        exec sleep 30 >/dev/null 2>&1 </dev/null
      SH

      write_stub File.join(bin, "dpkg"), <<~SH
        n=$(( $(cat "#{dpkg_count}" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "#{dpkg_count}"
        exit 0
      SH

      output, status = capture_bounded(SCRIPT, packages, bin, dir)

      {
        status: status,
        output: output,
        apt_calls: File.exist?(apt_count) ? File.read(apt_count).to_i : 0,
        dpkg_calls: File.exist?(dpkg_count) ? File.read(dpkg_count).to_i : 0,
        timeout_calls: File.exist?(timeout_log) ? File.read(timeout_log).lines.map(&:strip) : []
      }
    end
  end

  # Runs the script with a Ruby-side deadline, killing the whole process group on
  # expiry. Without this, a script that lost its bound would HANG the suite rather
  # than fail it — the exact failure this file is about, one level up.
  def capture_bounded(script, packages, bin, dir)
    read, write = IO.pipe
    pid = Process.spawn(
      { "PATH" => "#{bin}:#{ENV['PATH']}", "HOME" => dir, "APT_RETRY_BUDGETS" => "1 1 1" },
      script, *packages, out: write, err: write, pgroup: true
    )
    write.close

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HARNESS_DEADLINE
    done = nil
    until done
      done = Process.waitpid2(pid, Process::WNOHANG)
      break if done
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        Process.kill("KILL", -Process.getpgid(pid)) rescue nil
        Process.waitpid2(pid) rescue nil
        flunk "apt-retry did not finish within #{HARNESS_DEADLINE}s against a 1s budget — it is no " \
              "longer bounding its own fetch, which is the entire defect this file guards"
      end
      sleep 0.05
    end

    output = read.read
    read.close
    [ output, done[1].exitstatus ]
  end

  def write_stub(path, body)
    File.write(path, "#!/bin/bash\n#{body}")
    FileUtils.chmod(0o755, path)
  end
end
