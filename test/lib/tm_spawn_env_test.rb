# frozen_string_literal: true

# [unit] bin/tm starts every managed process under an ALLOW-LISTED environment.
#
# WHY (secrets-never-on-argv-or-desk-env, 2026-10-24). bin/tm's spawn handed web
# and Sidekiq the launching shell's whole environment, and an agent shell holds
# HEROKU_API_KEY, OP_SERVICE_ACCOUNT_TOKEN, CLAUDE_CODE_* and AGENT_API_SECRET.
# Puma and Sidekiq rename their process titles; on macOS `pgrep -fl` then prints a
# renamed process's environment, so one listing put the Heroku key into an agent
# transcript and the key was rotated.
#
# HOW. bash sources the REAL bin/tm (sourced, it defines and dispatches nothing)
# with fake credentials planted in its environment, then calls the real `spawn`
# with a stub "server" that writes its environment to a file and exits. Both
# spawn paths are driven: screen (when installed) and the nohup fallback.
#
# THE CONTROL. The same run with tm_scrub_env replaced by a no-op must hand the
# stub the credentials; otherwise "the stub saw no secret" could mean the fixture
# never planted one.
#
# Run directly:  ruby -Itest test/lib/tm_spawn_env_test.rb
require "minitest/autorun"
require "open3"
require "tmpdir"

class TmSpawnEnvTest < Minitest::Test
  TM = File.expand_path("../../bin/tm", __dir__)

  PLANTED = {
    "HEROKU_API_KEY" => "fake-heroku-key",
    "OP_SERVICE_ACCOUNT_TOKEN" => "fake-op-token",
    "OP_ADMIN_SERVICE_ACCOUNT_TOKEN" => "fake-op-admin-token",
    "AGENT_API_SECRET" => "fake-agent-secret",
    "AGENT_API_TOKEN" => "fake-agent-token",
    "GH_TOKEN" => "fake-gh-token",
    "GITHUB_TOKEN" => "fake-github-token",
    "CLAUDE_CODE_MESSAGING_TOKEN" => "fake-claude-messaging",
    "ANTHROPIC_API_KEY" => "fake-anthropic-key",
    "SOME_FUTURE_SECRET" => "fake-unlisted-name",
    "RESEND_API_KEY" => "fake-real-resend-key", # set, so dropped
    "SES_SMTP_PASSWORD" => ""                   # empty desk blank, so kept
  }.freeze

  ALLOWED = {
    "DATABASE_URL" => "postgres://localhost/tm_fixture",
    "REDIS_URL" => "redis://localhost:6379/9",
    "LANG" => "en_US.UTF-8",
    "ENABLE_FIAT_RAILS" => "true",  # docs/LOCAL_STACK.md boots with it
    "PAYMENT_PROVIDER" => "stripe"
  }.freeze

  def via_paths
    screen = system("command -v screen > /dev/null 2>&1")
    screen ? %w[screen nohup] : %w[nohup]
  end

  def launch(via, prelude: "")
    Dir.mktmpdir("tm-spawn-env") do |dir|
      dump = File.join(dir, "env.out")
      port = (39_000 + rand(900)).to_s
      script = <<~BASH
        source #{TM}
        #{prelude}
        spawn #{File.join(dir, 'stub.log')} #{File.join(dir, 'stub.pid')} /bin/sh -c "env > #{dump}"
      BASH
      env = PLANTED.merge(ALLOWED).merge("TM_PORT" => port, "TM_SPAWN_VIA" => via)
      _out, err, status = Open3.capture3(env, "bash", "-c", script)
      assert status.success?, "sourcing bin/tm and spawning failed (#{via}): #{err}"
      80.times { break if File.size?(dump); sleep 0.1 }
      assert File.size?(dump), "the stub never wrote its environment (#{via}): #{err}"
      sleep 0.1
      File.readlines(dump, chomp: true).filter_map { |l| l.split("=", 2) if l.include?("=") }.to_h
    end
  end

  def test_managed_processes_see_no_credential_and_keep_what_they_need
    via_paths.each do |via|
      seen = launch(via)

      (PLANTED.keys - ["SES_SMTP_PASSWORD"]).each { |name| refute seen.key?(name), "#{name} reached the process (#{via})" }
      refute(seen.values.any? { |v| v.start_with?("fake-") }, "a planted value reached the process (#{via}; names: #{seen.keys.sort.inspect})")
      ALLOWED.each { |name, value| assert_equal value, seen[name], "#{name} did not reach the process (#{via})" }
      assert seen.key?("PATH"), "PATH did not reach the process (#{via})"
      assert seen.key?("HOME"), "HOME did not reach the process (#{via})"
      assert_equal "", seen["SES_SMTP_PASSWORD"], "an empty desk mail blank must survive (#{via})"
    end
  end

  def test_control_without_the_scrub_the_stub_sees_the_secrets
    via_paths.each do |via|
      seen = launch(via, prelude: "tm_scrub_env(){ :; }")

      assert_equal "fake-heroku-key", seen["HEROKU_API_KEY"],
                   "the control saw no HEROKU_API_KEY (#{via}), so the scrub test proves nothing"
      assert_equal "fake-unlisted-name", seen["SOME_FUTURE_SECRET"]
    end
  end
end
