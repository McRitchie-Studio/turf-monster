# frozen_string_literal: true

# [unit] bin/e2e-parallel starts every Rails process under the desk allow-list.
#
# WHY (secrets-scrub-follow-ups, 2026-10-24). bin/tm and bin/parallel-server
# scrub their children (bin/lib/desk_env.sh, tm_scrub_env), but review found
# bin/e2e-parallel still started N test-env Pumas, their seeds and the Tailwind
# build with the launching shell's whole environment. Puma renames its process
# title, and on macOS `ps` and `pgrep -fl` then print the process's environment:
# that is how HEROKU_API_KEY reached a transcript.
#
# HOW. The REAL bin/e2e-parallel and bin/lib/desk_env.sh are copied into a temp
# root whose bin/rails is a stub that writes its environment to a temp name, moves
# it to a file named for its subcommand, and exits; lsof, curl, dropdb and npx are
# stubs on PATH. The run starts from a minimal environment (unsetenv_others) with
# fake credentials planted, so the operator's real ones never enter the test.
#
# THE WAIT IS A HANDSHAKE, NOT A CLOCK. `bin/rails server` is the one launch the
# lane backgrounds, and the lane kills it on teardown. So the curl stub stands in
# for /up and the two meet at a named pipe: the server stub moves its dump into
# place and then opens the pipe to write, and the curl stub reads it. Opening a
# pipe blocks until both ends are open, so curl answers only after the dump is
# whole and in place, and the server cannot exit before curl has asked. No step
# waits on a duration.
#
# WHY (turf-deterministic-ci). The curl stub used to poll for the dump with a fixed
# bound (1,200 polls of 0.05s) and answer at the bound either way. A starved
# runner that took longer than the bound got an "up" with no dump, and the test
# went red with "never ran `bin/rails server`" (six reds in CI, 2026-10-26 to
# 10-28, each green on re-run; refactor-review-2026-11-06 lane-health 2f). The one
# clock left is the harness's HANG_DEADLINE, which only stops a lane that never
# starts the server from hanging the suite; a green run never reaches it.
#
# THE CONTROL. The same run with tm_scrub_env a no-op must hand every stub the
# planted credentials, on the serialized path and on E2E_PARALLEL_SEED=1.
#
# Run directly:  ruby -Itest test/lib/e2e_parallel_env_test.rb
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

class E2eParallelEnvTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  PLANTED = {
    "HEROKU_API_KEY" => "fake-heroku-key",
    "OP_SERVICE_ACCOUNT_TOKEN" => "fake-op-token",
    "AGENT_API_SECRET" => "fake-agent-secret",
    "GH_TOKEN" => "fake-gh-token",
    "CLAUDE_CODE_MESSAGING_TOKEN" => "fake-claude-messaging",
    "SOME_FUTURE_SECRET" => "fake-unlisted-secret"
  }.freeze

  # Each Rails invocation the lane makes, by the stub's first argument.
  LAUNCHES = %w[tailwindcss:build db:drop runner server].freeze

  # The harness's hang guard (see THE WAIT). A green run finishes in seconds; this
  # only turns a lane that never starts the server into a red instead of a hang.
  HANG_DEADLINE = 300

  def stub(path, body)
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
  end

  # Runs the lane in its own process group, killed whole at HANG_DEADLINE, so a
  # stub left blocked on the pipe cannot outlive the test.
  def capture_bounded(env, script, dir)
    Open3.popen2e(env, "bash", script, "1", unsetenv_others: true, chdir: dir, pgroup: true) do |stdin, out, wait|
      stdin.close
      reader = Thread.new { out.read }
      unless wait.join(HANG_DEADLINE)
        Process.kill("KILL", -wait.pid)
        flunk "bin/e2e-parallel hung for #{HANG_DEADLINE}s: it never reached its /up check, " \
              "or never launched `bin/rails server`:\n#{reader.join(5)&.value}"
      end
      status = wait.value
      # Sweep the group: nothing the lane started may outlive the test.
      begin
        Process.kill("KILL", -wait.pid)
      rescue Errno::ESRCH
        nil
      end
      [reader.value, status]
    end
  end

  def run_lane(control: false, server_delay: nil, parallel_seed: false, write_delay: nil)
    Dir.mktmpdir("e2e-parallel-env") do |dir|
      bin = File.join(dir, "bin")
      stubs = File.join(dir, "stubs")
      FileUtils.mkdir_p([File.join(bin, "lib"), stubs])
      FileUtils.cp(File.join(ROOT, "bin/e2e-parallel"), bin)
      FileUtils.cp(File.join(ROOT, "bin/lib/desk_env.sh"), File.join(bin, "lib"))
      File.write(File.join(bin, "lib/desk_env.sh"), "\ntm_scrub_env(){ :; }\n", mode: "a") if control
      slow_start = server_delay ? %([ "$1" = server ] && sleep #{server_delay}\n) : ""
      slow_write = write_delay ? %([ "$1" = server ] && { echo DUMP_STARTED=1; sleep #{write_delay}; }; ) : ""
      up = File.join(dir, "up.fifo")
      File.mkfifo(up)
      # After the move, the server stub opens the pipe and blocks there until curl reads.
      signal_up = %([ "$1" = server ] && : > "#{up}"; )
      stub(File.join(bin, "rails"), %(#{slow_start}{ #{slow_write}env; } > "#{dir}/env-$1.tmp" && mv "#{dir}/env-$1.tmp" "#{dir}/env-$1.out" && { #{signal_up}:; }))
      stub(File.join(stubs, "lsof"), "exit 0")
      stub(File.join(stubs, "curl"), %(cat "#{up}" >/dev/null))
      stub(File.join(stubs, "dropdb"), "exit 0")
      stub(File.join(stubs, "npx"), "echo '1 passed'")

      env = {
        "PATH" => [stubs, RbConfig::CONFIG["bindir"], "/usr/bin", "/bin"].join(":"),
        "HOME" => dir, "LANG" => "en_US.UTF-8", "LC_MESSAGES" => "en_US.UTF-8",
        "PLAYWRIGHT_SEED" => "42"
      }.merge(PLANTED)
      env["E2E_PARALLEL_SEED"] = "1" if parallel_seed
      out, status = capture_bounded(env, File.join(bin, "e2e-parallel"), dir)
      assert status.success?, "bin/e2e-parallel failed:\n#{out}"
      assert_includes out, (parallel_seed ? "parallel seed" : "serialized"), "the lane took the wrong launch path"
      LAUNCHES.to_h do |cmd|
        file = File.join(dir, "env-#{cmd}.out")
        assert File.size?(file), "bin/e2e-parallel never ran `bin/rails #{cmd}`:\n#{out}"
        [cmd, File.readlines(file, chomp: true).filter_map { |l| l.split("=", 2) if l.include?("=") }.to_h]
      end
    end
  end

  def assert_scrubbed_stacks(lane)
    lane.each do |cmd, seen|
      PLANTED.each_key { |name| refute seen.key?(name), "#{name} reached `bin/rails #{cmd}`" }
      refute(seen.values.any? { |v| v.start_with?("fake-") }, "a planted value reached `bin/rails #{cmd}`")
      %w[PATH HOME].each { |name| assert seen.key?(name), "#{name} is missing from `bin/rails #{cmd}`" }
      assert_equal "en_US.UTF-8", seen["LC_MESSAGES"], "the locale family must reach `bin/rails #{cmd}`"
      next if cmd == "tailwindcss:build"

      assert_equal "test", seen["RAILS_ENV"], "`bin/rails #{cmd}` lost its stack's RAILS_ENV"
      assert_equal "postgres:///turf_monster_e2e_pw_0", seen["TEST_DATABASE_URL"], "`bin/rails #{cmd}` lost its stack's DB"
      assert_equal "true", seen["ENABLE_COINFLOW"], "`bin/rails #{cmd}` lost an onramp rail"
    end
  end

  def test_every_rails_process_sees_no_credential_and_keeps_its_stack
    assert_scrubbed_stacks(run_lane)
  end

  def test_the_seed_keeps_its_own_variables
    assert_equal "42", run_lane.fetch("runner")["PLAYWRIGHT_SEED"], "e2e/seed.rb reads PLAYWRIGHT_SEED"
  end

  def test_the_lane_keeps_a_slow_server_up_until_it_has_answered
    assert_equal "test", run_lane(server_delay: 2).fetch("server")["RAILS_ENV"]
  end

  def assert_every_process_leaks(lane)
    lane.each do |cmd, seen|
      assert_equal "fake-heroku-key", seen["HEROKU_API_KEY"],
                   "the control saw no HEROKU_API_KEY in `bin/rails #{cmd}`, so the scrub test proves nothing"
      assert_equal "fake-unlisted-secret", seen["SOME_FUTURE_SECRET"]
    end
  end

  def test_control_without_the_scrub_every_process_sees_the_secrets
    assert_every_process_leaks(run_lane(control: true))
  end

  # E2E_PARALLEL_SEED=1 is its own launch branch with its own tm_scrub_env, so the
  # serialized tests say nothing about it. Its server dump is written slowly: the
  # lane kills the server once curl answers, so a dump that was not moved into place
  # reaches the reader cut short.
  def parallel_lane(**opts) = run_lane(parallel_seed: true, write_delay: 0.5, **opts)

  def test_parallel_seed_every_rails_process_sees_no_credential_and_keeps_its_stack
    lane = parallel_lane
    assert_scrubbed_stacks(lane)
    assert_equal "42", lane.fetch("runner")["PLAYWRIGHT_SEED"], "e2e/seed.rb reads PLAYWRIGHT_SEED"
  end

  def test_control_parallel_seed_without_the_scrub_every_process_sees_the_secrets
    assert_every_process_leaks(parallel_lane(control: true))
  end
end
