# frozen_string_literal: true

# [unit] bin/dev starts foreman (web, Tailwind, Sidekiq) under the desk allow-list.
#
# WHY (secrets-scrub-follow-ups, 2026-10-24). bin/tm and bin/e2e-parallel scrub
# their children through bin/lib/desk_env.sh; bin/dev handed foreman, and so
# Puma and Sidekiq, the launching shell's whole environment. Both rename their
# process titles, and on macOS `ps` then prints a renamed process's environment.
#
# HOW. The REAL bin/dev runs from a minimal environment (unsetenv_others) with
# fake credentials planted, `gem` and `foreman` stubbed on PATH; the foreman stub
# writes its environment to a file. THE CONTROL: a copy of bin/dev beside a
# desk_env.sh whose tm_scrub_env is a no-op must hand the stub the credentials.
#
# Run directly:  ruby -Itest test/lib/bin_dev_env_test.rb
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

class BinDevEnvTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  PLANTED = {
    "HEROKU_API_KEY" => "fake-heroku-key",
    "OP_SERVICE_ACCOUNT_TOKEN" => "fake-op-token",
    "AGENT_API_SECRET" => "fake-agent-secret",
    "GH_TOKEN" => "fake-gh-token",
    "SOME_FUTURE_SECRET" => "fake-unlisted-secret"
  }.freeze

  def stub(path, body)
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
  end

  def run_dev(control: false)
    Dir.mktmpdir("bin-dev-env") do |dir|
      dump = File.join(dir, "env.out")
      stubs = File.join(dir, "stubs")
      FileUtils.mkdir_p(stubs)
      stub(File.join(stubs, "gem"), "exit 0") # foreman answers installed; nothing is installed
      stub(File.join(stubs, "foreman"), "env > #{dump}")
      dev = File.join(ROOT, "bin/dev")
      if control
        bin = File.join(dir, "bin")
        FileUtils.mkdir_p(File.join(bin, "lib"))
        FileUtils.cp(dev, bin)
        File.write(File.join(bin, "lib/desk_env.sh"),
                   File.read(File.join(ROOT, "bin/lib/desk_env.sh")) + "\ntm_scrub_env(){ :; }\n")
        dev = File.join(bin, "dev")
      end
      env = {
        "PATH" => [stubs, RbConfig::CONFIG["bindir"], "/usr/bin", "/bin"].join(":"),
        "HOME" => dir, "LANG" => "en_US.UTF-8", "LC_MESSAGES" => "en_US.UTF-8"
      }.merge(PLANTED)
      out, status = Open3.capture2e(env, "sh", dev, unsetenv_others: true, chdir: dir)
      assert status.success?, "bin/dev failed:\n#{out}"
      assert File.size?(dump), "foreman was never started:\n#{out}"
      File.readlines(dump, chomp: true).filter_map { |l| l.split("=", 2) if l.include?("=") }.to_h
    end
  end

  def test_foreman_sees_no_credential_and_keeps_what_bin_dev_sets
    seen = run_dev

    PLANTED.each_key { |name| refute seen.key?(name), "#{name} reached foreman" }
    refute(seen.values.any? { |v| v.start_with?("fake-") }, "a planted value reached foreman")
    %w[PATH HOME].each { |name| assert seen.key?(name), "#{name} is missing" }
    assert_equal "en_US.UTF-8", seen["LC_MESSAGES"]
    assert_equal "3000", seen["PORT"], "bin/dev's PORT default must reach foreman"
    assert_equal "true", seen["RUBY_DEBUG_OPEN"], "the debug gem switches bin/dev sets must reach foreman"
    assert_equal "true", seen["RUBY_DEBUG_LAZY"]
  end

  def test_control_without_the_scrub_foreman_sees_the_secrets
    seen = run_dev(control: true)

    assert_equal "fake-heroku-key", seen["HEROKU_API_KEY"], "the control saw no HEROKU_API_KEY, so the test proves nothing"
    assert_equal "fake-unlisted-secret", seen["SOME_FUTURE_SECRET"]
  end
end
