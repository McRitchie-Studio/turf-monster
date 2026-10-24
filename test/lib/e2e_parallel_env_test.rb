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
# root whose bin/rails is a stub that writes its environment to a file named for
# its subcommand and exits; lsof, curl, dropdb and npx are stubs on PATH. The run
# starts from a minimal environment (unsetenv_others) with fake credentials
# planted, so the operator's real ones never enter the test.
#
# THE CONTROL. The same run with tm_scrub_env a no-op must hand every stub the
# planted credentials.
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

  def stub(path, body)
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
  end

  def run_lane(control: false)
    Dir.mktmpdir("e2e-parallel-env") do |dir|
      bin = File.join(dir, "bin")
      stubs = File.join(dir, "stubs")
      FileUtils.mkdir_p([File.join(bin, "lib"), stubs])
      FileUtils.cp(File.join(ROOT, "bin/e2e-parallel"), bin)
      FileUtils.cp(File.join(ROOT, "bin/lib/desk_env.sh"), File.join(bin, "lib"))
      File.write(File.join(bin, "lib/desk_env.sh"), "\ntm_scrub_env(){ :; }\n", mode: "a") if control
      stub(File.join(bin, "rails"), %(env > "#{dir}/env-$1.out"))
      stub(File.join(stubs, "lsof"), "exit 0")
      stub(File.join(stubs, "curl"), "exit 0")
      stub(File.join(stubs, "dropdb"), "exit 0")
      stub(File.join(stubs, "npx"), "echo '1 passed'")

      env = {
        "PATH" => [stubs, RbConfig::CONFIG["bindir"], "/usr/bin", "/bin"].join(":"),
        "HOME" => dir, "LANG" => "en_US.UTF-8", "LC_MESSAGES" => "en_US.UTF-8",
        "PLAYWRIGHT_SEED" => "42"
      }.merge(PLANTED)
      out, status = Open3.capture2e(env, "bash", File.join(bin, "e2e-parallel"), "1",
                                    unsetenv_others: true, chdir: dir)
      assert status.success?, "bin/e2e-parallel failed:\n#{out}"
      LAUNCHES.to_h do |cmd|
        file = File.join(dir, "env-#{cmd}.out")
        assert File.size?(file), "bin/e2e-parallel never ran `bin/rails #{cmd}`:\n#{out}"
        [cmd, File.readlines(file, chomp: true).filter_map { |l| l.split("=", 2) if l.include?("=") }.to_h]
      end
    end
  end

  def test_every_rails_process_sees_no_credential_and_keeps_its_stack
    run_lane.each do |cmd, seen|
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

  def test_the_seed_keeps_its_own_variables
    assert_equal "42", run_lane.fetch("runner")["PLAYWRIGHT_SEED"], "e2e/seed.rb reads PLAYWRIGHT_SEED"
  end

  def test_control_without_the_scrub_every_process_sees_the_secrets
    run_lane(control: true).each do |cmd, seen|
      assert_equal "fake-heroku-key", seen["HEROKU_API_KEY"],
                   "the control saw no HEROKU_API_KEY in `bin/rails #{cmd}`, so the scrub test proves nothing"
      assert_equal "fake-unlisted-secret", seen["SOME_FUTURE_SECRET"]
    end
  end
end
