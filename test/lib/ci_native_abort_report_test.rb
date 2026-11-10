# frozen_string_literal: true

# Guard: A NATIVE ABORT IN A CI RUBY PROCESS NAMES ITSELF (task turf-server-boot-malloc-abort).
#
# Run 42745469708's e2e seed runner died of `malloc_consolidate(): unaligned fastbin
# chunk detected`, exit 134, with no stack: Ruby reports SIGSEGV but not SIGABRT, and
# glibc's heap checks end in abort(). .github/scripts/native-abort-report.c is preloaded
# in the `test` and `playwright` jobs so the next abort prints the C backtrace and Ruby's
# [BUG] report. These tests pin the wiring and, on Linux (the CI lane image), prove the
# shim on a real glibc abort: a double free.
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

class CiNativeAbortReportTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  CI = File.join(ROOT, ".github/workflows/ci.yml")
  SCRIPT = File.join(ROOT, ".github/scripts/native-abort-report.sh")
  SHIM = File.join(ROOT, ".github/scripts/native-abort-report.c")
  STEP = ".github/scripts/native-abort-report.sh"
  LANES = %w[test playwright].freeze

  def steps(lane) = Array((YAML.load_file(CI, aliases: true) || {}).dig("jobs", lane, "steps"))

  def ruby_setup?(step) = step["uses"].to_s.start_with?("ruby/setup-ruby")

  # The preload reaches only the steps AFTER it ($GITHUB_ENV), so it must sit right
  # after Ruby is set up and before the first step that runs the app.
  def test_each_ruby_lane_preloads_the_reporter_before_it_runs_ruby
    LANES.each do |lane|
      all = steps(lane)
      setup = all.index { |s| ruby_setup?(s) } or flunk "#{lane} sets up no Ruby"
      preload = all.index { |s| s["run"].to_s.strip == STEP } or flunk "#{lane} does not preload the reporter"
      first_app = all.index { |s| s["run"].to_s.match?(%r{bin/rails|bin/e2e|npm test}) }
      assert_operator preload, :>, setup, "#{lane}: the reporter needs the runner's toolchain, after setup-ruby"
      assert_operator preload, :<, first_app, "#{lane}: the reporter must precede the first app step"
    end
  end

  def test_the_build_fails_loudly_and_exports_the_preload
    body = File.read(SCRIPT)
    assert File.executable?(SCRIPT), "the step runs the script directly"
    assert_includes body, "set -eu", "a build failure must fail the step, not leave the next abort mute"
    assert_match(/LD_PRELOAD=\$out" >> "\$GITHUB_ENV"/, body)
  end

  # The shim must stay inert outside Ruby (node, Chromium, sh share the job's env) and
  # must keep the abort fatal.
  def test_the_shim_acts_only_in_ruby_and_keeps_the_abort_fatal
    src = File.read(SHIM)
    assert_includes src, 'readlink("/proc/self/exe"'
    assert_includes src, 'strncmp(base, "ruby", 4)'
    assert_includes src, "signal(SIGABRT, SIG_DFL)", "the second abort must end the process"
    assert_includes src, "alarm(30)", "a report that deadlocks in malloc must not hang the job"
    assert_includes src, 'dlsym(RTLD_DEFAULT, "rb_bug")'
  end

  # [integration] The real thing, in the lane image: a glibc abort in Ruby, with and
  # without the shim. Without it the process dies mute; with it the same abort prints
  # the C backtrace and Ruby's report naming the Ruby method, and still exits 134.
  def test_a_glibc_abort_in_ruby_prints_its_stack_under_the_shim
    skip "the shim is Linux/glibc only (the CI lane image)" unless RbConfig::CONFIG["host_os"].include?("linux")
    skip "no C compiler" unless system("cc --version", out: File::NULL, err: File::NULL)

    Dir.mktmpdir do |dir|
      so = File.join(dir, "native-abort-report.so")
      _, err, st = Open3.capture3("cc", "-shared", "-fPIC", "-O2", "-Wall", "-Werror", "-o", so, SHIM)
      assert st.success?, "the shim must compile cleanly: #{err}"

      crash = 'require "fiddle"; def seed_phase = (p = Fiddle.malloc(24); Fiddle.free(p); Fiddle.free(p)); seed_phase'
      env = { "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil, "LD_PRELOAD" => nil }

      _, mute, bare = Open3.capture3(env, RbConfig.ruby, "-e", crash)
      assert_equal Signal.list.fetch("ABRT"), bare.termsig, "control: a double free aborts"
      refute_includes mute, "seed_phase", "control: without the shim the abort names no Ruby frame"

      _, report, shimmed = Open3.capture3(env.merge("LD_PRELOAD" => so), RbConfig.ruby, "-e", crash)
      assert_equal Signal.list.fetch("ABRT"), shimmed.termsig, "the abort stays an abort (exit 134)"
      assert_includes report, "native-abort-report: SIGABRT in a Ruby process"
      assert_match(/libc\.so\.6\(__libc_free/, report, "the C backtrace names the failing libc call")
      assert_includes report, "[BUG] native abort (SIGABRT)"
      assert_match(/-e:1:in .*seed_phase/, report, "Ruby's report names the method that was running")
    end
  end
end
