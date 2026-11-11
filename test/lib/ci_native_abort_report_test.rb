# frozen_string_literal: true

# Guard: A NATIVE ABORT IN A CI RUBY PROCESS NAMES ITSELF (task turf-server-boot-malloc-abort).
#
# Run 42745469708's e2e seed runner died of `malloc_consolidate(): unaligned fastbin
# chunk detected`, exit 134, with no stack: Ruby reports SIGSEGV but not SIGABRT, and
# glibc's heap checks end in abort(). .github/scripts/native-abort-report.c is preloaded
# in the `test` and `playwright` jobs so the next abort prints the C backtrace and Ruby's
# [BUG] report. These tests pin the wiring and, on Linux (the CI lane image), prove the
# shim on a real glibc abort: a double free, and a malloc_consolidate abort that holds
# the arena lock. Task turf-seed-native-crash-cause added the re-entry guard: Ruby's
# own rb_bug() ends in abort(), and the shim must not print a second [BUG] after it.
#
# THE CHILD SEES ONLY WHAT THE TEST GIVES IT (task turf-native-abort-control-env).
# studio-engine's Consumer CI run 42941340814 failed the arena-lock control with an
# EMPTY stderr; run 42941415917 of the same lane passed on the same Turf commit
# (c957d0c6), same lane image, same Ruby, minutes later. So the lane was not the
# cause. Nor is a tty: Ubuntu 24.04's glibc 2.39 has no LIBC_FATAL_STDERR_ and
# writes its fatal message to stderr unconditionally, and the tty test below proves
# it with a controlling terminal open. What differed was the PARENT: a suite worker
# that had already run other tests. The child used to inherit that worker's whole
# environment and its process group. Now each child starts from a fixed, minimal
# environment (CHILD_ENV, unsetenv_others) in a new session with no controlling
# tty (NO_TTY), and every failure prints the child's signal, exit code and output.
require "minitest/autorun"
require "open3"
require "pty"
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
    assert_includes src, "report_alarm = 30;", "a report that deadlocks in malloc must not hang the job"
    assert_includes src, "alarm(report_alarm)"
    assert_includes src, 'dlsym(RTLD_DEFAULT, "rb_bug")'
  end

  # [unit] THE RE-ENTRY GUARD. Ruby's rb_bug() prints its report, then calls abort().
  # The shim defines abort() to mark a call from Ruby's own object, and the handler
  # then lets the abort through. Symbol names cannot do this: GCC puts rb_bug's abort
  # call in an unnamed .cold part. glibc's heap checks abort inside libc, unmarked.
  def test_an_abort_from_rubys_own_crash_report_is_not_reported_twice
    src = File.read(SHIM)
    assert_match(/^void abort\(void\) \{/, src, "the shim must see Ruby's die() -> abort() call")
    assert_includes src, 'dlsym(RTLD_NEXT, "abort")', "the abort must still reach glibc's"
    assert_includes src, "caller.dli_fbase == ruby_core_base", "only Ruby's own object marks the abort"
    assert_match(/if \(ruby_reported_already\) \{.*?raise\(SIGABRT\)/m, src, "a marked abort passes through")
    handler = src[/^static void on_abort\(int sig\) \{.*?^\}/m].to_s
    refute_empty handler, "the SIGABRT handler is on_abort"
    refute_includes handler, "dlsym(", "the handler must not dlsym: a failed lookup allocates"
  end

  # The test and playwright steps each log a host-side ld.so line under the preload.
  # ci.yml must say it is expected, so nobody chases it as the crash.
  def test_ci_says_the_host_side_preload_line_is_expected
    body = File.read(CI)
    assert_match(/EXPECTED NOISE:.*?cannot be preloaded.*?It is not a fault\./m, body)
    assert_includes File.read(SCRIPT), "preload check passed", "the build proves the preload loads in the step"
  end

  # [integration] The real thing, in the lane image: a glibc abort in Ruby, with and
  # without the shim. Without it the process dies mute; with it the same abort prints
  # the C backtrace and Ruby's report naming the Ruby method, and still exits 134.
  def test_a_glibc_abort_in_ruby_prints_its_stack_under_the_shim
    with_shim do |so, _dir|
      crash = 'require "fiddle"; def seed_phase = (p = Fiddle.malloc(24); Fiddle.free(p); Fiddle.free(p)); seed_phase'
      out, mute, bare = run_child({}, crash)
      assert_equal Signal.list.fetch("ABRT"), bare.termsig, "control: a double free aborts. #{child(bare, out, mute)}"
      refute_includes mute, "seed_phase", "control: without the shim the abort names no Ruby frame"

      out, report, shimmed = run_child({ "LD_PRELOAD" => so }, crash)
      assert_equal Signal.list.fetch("ABRT"), shimmed.termsig, "the abort stays an abort (exit 134). #{child(shimmed, out, report)}"
      assert_includes report, "native-abort-report: SIGABRT in a Ruby process"
      assert_match(/libc\.so\.6\(__libc_free/, report, "the C backtrace names the failing libc call")
      assert_includes report, "[BUG] native abort (SIGABRT)"
      assert_match(/-e:1:in .*seed_phase/, report, "Ruby's report names the method that was running")
    end
  end

  # [integration] RE-ENTRY: Ruby's own rb_bug() under the shim prints ONE [BUG]: its
  # own. Before the guard, the shim answered rb_bug's abort with a second report that
  # blamed heap corruption.
  def test_rubys_own_rb_bug_prints_one_report_under_the_shim
    with_shim do |so, _dir|
      bug = 'require "fiddle"; Fiddle::Function.new(Fiddle::Handle::DEFAULT["rb_bug"], ' \
            '[Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID).call("own bug")'
      out, report, st = run_child({ "LD_PRELOAD" => so }, bug)
      assert_equal Signal.list.fetch("ABRT"), st.termsig, "rb_bug still ends the process by abort. #{child(st, out, report)}"
      assert_equal 1, report.scan("[BUG]").size, "one report, Ruby's own:\n#{report[-2000..]}"
      assert_includes report, "[BUG] own bug"
      assert_includes report, "Ruby's own crash report is above; not reporting again"
      refute_includes report, "native abort (SIGABRT)"
    end
  end

  # [integration] ARENA LOCK HELD: a forged fastbin pointer makes the next large malloc
  # run malloc_consolidate, which aborts INSIDE malloc, holding the arena lock (the
  # process has had a second thread, so glibc locks). This is run 42745469708's abort.
  # The report must name the Ruby method before anything in it can deadlock in malloc,
  # and the alarm must end the process if it does.
  FASTBIN_C = <<~C
    #include <stdint.h>
    #include <stdlib.h>
    void corrupt_fastbin_and_consolidate(void) {
      void *fill[7];
      for (int i = 0; i < 7; i++) fill[i] = malloc(40);
      void *victim = malloc(40);
      void *guard = malloc(40);
      for (int i = 0; i < 7; i++) free(fill[i]);  /* fill the tcache bin */
      free(victim);                                /* so this one is a fastbin chunk */
      uintptr_t *fd = (uintptr_t *)victim;         /* forge its safe-linked fd: 0x8 */
      *fd = (((uintptr_t)fd) >> 12) ^ (uintptr_t)0x8;
      void *big = malloc(4096);                    /* large request: consolidate */
      (void)guard; (void)big;
    }
  C

  def test_an_arena_lock_held_abort_prints_the_ruby_backtrace_and_ends_within_the_alarm
    with_shim do |so, dir|
      crash = fastbin_crash(dir)

      out, mute, bare = run_child({}, crash)
      assert_includes mute, CONSOLIDATE_ABORT, "control: the real abort. #{child(bare, out, mute)}"
      assert_equal Signal.list.fetch("ABRT"), bare.termsig, "control: #{child(bare, out, mute)}"

      alarm = 3
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out, report, shimmed = run_child({ "LD_PRELOAD" => so, "NATIVE_ABORT_REPORT_ALARM" => alarm.to_s }, crash)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_operator elapsed, :<, alarm + 10, "the process must end within the alarm, not hang the job"
      assert_includes [Signal.list.fetch("ABRT"), Signal.list.fetch("ALRM")], shimmed.termsig, child(shimmed, out, report)
      assert_match(/libc\.so\.6\(malloc\+/, report, "the C backtrace names the malloc call that aborted")
      assert_match(/-e:1:in .*seed_phase/, report, "the Ruby backtrace names the method that was running")
      if shimmed.termsig == Signal.list.fetch("ALRM")
        assert_includes report, "the report stalled past its alarm", "a stalled report says why it ended"
      end
    end
  end

  # [integration] THE TTY QUESTION, ANSWERED. The engine lane's red was first blamed on
  # glibc writing its fatal message to /dev/tty when one is open (the old
  # LIBC_FATAL_STDERR_ rule). This runs the same abort with a controlling terminal
  # OPEN (PTY.spawn makes the pty the child's controlling tty, and the launcher proves
  # /dev/tty opens) and stderr sent to a file: the message must land on stderr. The
  # control above is the no-tty half: a new session has no controlling terminal.
  def test_glibcs_fatal_message_reaches_stderr_with_a_controlling_tty_open
    with_shim do |_so, dir|
      crash = fastbin_crash(dir)
      err_path = File.join(dir, "tty-run.err")
      status, tty_out = run_under_tty(err_path, crash)
      err = File.read(err_path)

      refute_includes tty_out, "no controlling tty", "the launcher must have a controlling terminal: #{tty_out}"
      assert_equal Signal.list.fetch("ABRT"), status.termsig, child(status, tty_out, err)
      assert_includes err, CONSOLIDATE_ABORT, "with a tty open, glibc still writes to stderr. #{child(status, tty_out, err)}"
    end
  end

  # [unit] THE BARE CONTROL IS SHIM-FREE IN BOTH LANES. Turf's own test job exports
  # LD_PRELOAD (the real shim) to the whole suite; studio-engine's Consumer CI lane
  # does not. The child must see exactly CHILD_ENV + HOME and nothing the worker
  # carries, so a later "just inherit the env" refactor cannot turn the control into
  # a shimmed run in one lane and a bare one in the other. Runs on every OS.
  def test_a_child_inherits_nothing_from_the_suite_worker
    planted = { "LD_PRELOAD" => "/nonexistent/native-abort-report.so", "GLIBC_TUNABLES" => "glibc.malloc.tcache_count=100" }
    saved = planted.to_h { |k, _| [k, ENV.fetch(k, nil)] }
    planted.each { |k, v| ENV[k] = v }
    out, err, st = run_child({}, "print ENV.keys.sort.join(',')")
    assert st.success?, child(st, out, err)
    # macOS's loader adds __CF_USER_TEXT_ENCODING to every process; Linux adds nothing.
    seen = out.split(",").reject { |k| k.start_with?("__CF_") }
    assert_equal (CHILD_ENV.keys + ["HOME"]).sort, seen, "the child's whole environment"
    planted.each_key { |k| refute_includes out.split(","), k, "#{k} leaked from the worker into the child" }
  ensure
    saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  private

  CONSOLIDATE_ABORT = "malloc_consolidate(): unaligned fastbin chunk detected"

  # The whole environment a child Ruby gets. Nothing is inherited from the suite
  # worker (unsetenv_others): not RUBYOPT, not BUNDLE_*, not LD_PRELOAD, not any
  # variable an earlier test left behind.
  CHILD_ENV = { "PATH" => "/usr/local/bin:/usr/bin:/bin", "LANG" => "C.UTF-8" }.freeze

  # A new session, so the child has no controlling terminal and shares no process
  # group with the suite: a signal sent to the worker's group cannot reach it. The
  # launcher then execs the child in place, so the status is the child's own.
  NO_TTY = "Process.setsid; exec(*ARGV)"

  # The launcher under a pty: /dev/tty must open (else it says so and exits), then
  # stderr goes to the file named first, and the child execs in place.
  WITH_TTY = 'begin; File.open("/dev/tty", "w").close; rescue SystemCallError; puts "no controlling tty"; exit 2; end; ' \
             "$stderr.reopen(ARGV.shift, \"w\"); exec(*ARGV)"

  def run_child(env, script)
    Open3.capture3(CHILD_ENV.merge("HOME" => Dir.tmpdir).merge(env), RbConfig.ruby, "-e", NO_TTY, RbConfig.ruby, "-e", script,
                   unsetenv_others: true)
  end

  def run_under_tty(err_path, script)
    env = CHILD_ENV.merge("HOME" => Dir.tmpdir)
    PTY.spawn(env, RbConfig.ruby, "-e", WITH_TTY, err_path, RbConfig.ruby, "-e", script, unsetenv_others: true) do |r, w, pid|
      w.close
      out = +""
      begin
        r.each_char { |c| out << c }
      rescue Errno::EIO
        nil # the pty closes when the child ends
      end
      return [Process.wait2(pid).last, out]
    end
  end

  # How a child ended, so a red names its own cause instead of an empty string.
  def child(status, out, err)
    "child ended #{status.inspect} (termsig=#{status.termsig.inspect} exit=#{status.exitstatus.inspect}); " \
      "stdout=#{out.to_s[-500..] || out.inspect} stderr=#{err.to_s[-1500..] || err.inspect}"
  end

  def fastbin_crash(dir)
    src = File.join(dir, "fastbin.c")
    helper = File.join(dir, "fastbin.so")
    File.write(src, FASTBIN_C)
    _, err, st = Open3.capture3("cc", "-shared", "-fPIC", "-O0", "-o", helper, src)
    assert st.success?, "the fastbin helper must compile: #{err}"

    'require "fiddle"; Thread.new {}.join; ' \
      "f = Fiddle::Function.new(Fiddle.dlopen(#{helper.dump})['corrupt_fastbin_and_consolidate'], [], Fiddle::TYPE_VOID); " \
      "def seed_phase(f) = f.call; seed_phase(f)"
  end

  def with_shim
    skip "the shim is Linux/glibc only (the CI lane image)" unless RbConfig::CONFIG["host_os"].include?("linux")
    skip "no C compiler" unless system("cc --version", out: File::NULL, err: File::NULL)

    Dir.mktmpdir do |dir|
      so = File.join(dir, "native-abort-report.so")
      _, err, st = Open3.capture3("cc", "-shared", "-fPIC", "-O2", "-Wall", "-Werror", "-o", so, SHIM)
      assert st.success?, "the shim must compile cleanly: #{err}"
      yield so, dir
    end
  end
end
