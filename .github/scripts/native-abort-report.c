// native-abort-report: make a glibc heap abort inside a Ruby process name itself.
//
// WHY. Twice the e2e seed runner (`bin/rails runner e2e/seed.rb`, the middle command
// of Playwright's webServer) died of native heap corruption in CI:
//   - run 41001965509 (2026-10-30, bare runner): SIGSEGV. Ruby printed its [BUG]
//     report: GC marking an ObjectSpace::WeakMap (wmap_mark_weak_table_i) read a
//     garbage entry, inside Nfl::CacheExpectedTeamTotals.
//   - run 42745469708 (2026-11-10, lane image): `malloc_consolidate(): unaligned
//     fastbin chunk detected`, then `Aborted (core dumped)`, exit 134. NO report.
// Ruby installs a crash reporter for SIGSEGV, SIGBUS, SIGILL and SIGFPE, but not for
// SIGABRT (signal.c). glibc's malloc checks end in abort(), so the second crash left
// no Ruby backtrace, no C backtrace and no file:line. The cause stays unproven until
// one abort carries its stack. This shim supplies that stack.
//
// WHAT IT DOES. Loaded with LD_PRELOAD, it installs a SIGABRT handler in Ruby
// processes only (it checks /proc/self/exe). Node, Chromium and sh get no handler;
// in them the abort() defined below only forwards to glibc's.
// On abort it writes glibc's own C backtrace (backtrace_symbols_fd: no malloc), then
// calls Ruby's rb_bug(), which prints the full [BUG] report (control frames, the Ruby
// backtrace, the C backtrace, the loaded libraries) and dies by abort() again. The
// handler resets SIGABRT to the default first, so the second abort ends the process
// with the same exit code as before (134).
//
// TWO LIMITS, both measured in the lane image (task turf-seed-native-crash-cause):
//   - glibc can abort with the malloc arena lock held (malloc_consolidate does). The
//     report then prints the C backtrace and Ruby's backtrace, and deadlocks later, in
//     its own C-level section. A SIGALRM armed first (30 s) ends the process (exit
//     142) with a line saying why, instead of hanging the job.
//   - Ruby's own rb_bug() ends in abort() after its report. The shim lets that abort
//     through with one line and no second [BUG] (see abort() below).
//
// It changes no allocation and no behaviour before an abort. It is a reporter, not
// a fix. Built and exported by .github/scripts/native-abort-report.sh.
// Guard: test/lib/ci_native_abort_report_test.rb.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <execinfo.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef void (*rb_bug_fn)(const char *fmt, ...);

static void say(const char *s) {
  ssize_t ignored = write(2, s, strlen(s));
  (void)ignored;
}

static int running_ruby(void) {
  char exe[4096];
  ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
  if (n <= 0) return 0;
  exe[n] = '\0';
  const char *base = strrchr(exe, '/');
  base = base ? base + 1 : exe;
  return strncmp(base, "ruby", 4) == 0;
}

// Ruby's own crash path (rb_bug, rb_assert_failure) ends in die() -> abort() AFTER it
// has printed its [BUG] report. That abort must pass through untouched: a second
// report would blame a heap corruption that never happened. Ruby calls abort() through
// the dynamic linker, so this definition sees that call and records it when the caller
// is Ruby's own object (the one that defines rb_bug). glibc's heap checks call abort
// from inside libc and never reach here, so they are still reported. Symbol names
// cannot tell the two apart: GCC moves rb_bug's abort call into an unnamed .cold part.
// Everything is resolved once, in the constructor, while the heap is sound: a failed
// dlsym allocates its error text, and abort() may run with the arena lock held.
typedef void (*abort_fn)(void);
static abort_fn real_abort;
static rb_bug_fn ruby_bug;
static void *ruby_core_base;
static volatile sig_atomic_t ruby_reported_already;
static unsigned report_alarm = 30;

void abort(void) {
  Dl_info caller;
  if (ruby_core_base && dladdr(__builtin_return_address(0), &caller) &&
      caller.dli_fbase == ruby_core_base)
    ruby_reported_already = 1;
  if (real_abort) real_abort();
  signal(SIGABRT, SIG_DFL);
  raise(SIGABRT);
  _exit(134);
}

static void on_stalled_report(int sig) {
  (void)sig;
  say("\n-- native-abort-report: the report stalled past its alarm (the abort likely "
      "holds the malloc arena lock); ending the process --\n");
  signal(SIGALRM, SIG_DFL);
  raise(SIGALRM);
}

static void on_abort(int sig) {
  (void)sig;
  signal(SIGABRT, SIG_DFL);

  if (ruby_reported_already) {
    say("-- native-abort-report: Ruby's own crash report is above; not reporting "
        "again --\n");
    raise(SIGABRT);
    return;
  }

  signal(SIGALRM, on_stalled_report);
  alarm(report_alarm);

  say("\n-- native-abort-report: SIGABRT in a Ruby process (glibc or a native "
      "extension called abort()) --\n-- C backtrace at the abort --\n");
  void *frames[96];
  int n = backtrace(frames, 96);
  backtrace_symbols_fd(frames, n, 2);

  if (ruby_bug) {
    say("-- Ruby's crash report follows --\n");
    ruby_bug("native abort (SIGABRT): heap corruption or a native assertion; "
           "see the native-abort-report C backtrace above");
  }
  say("-- native-abort-report: rb_bug not found; re-raising SIGABRT --\n");
  raise(SIGABRT);
}

__attribute__((constructor)) static void native_abort_report_install(void) {
  real_abort = (abort_fn)dlsym(RTLD_NEXT, "abort");
  if (!running_ruby()) return;
  ruby_bug = (rb_bug_fn)dlsym(RTLD_DEFAULT, "rb_bug");
  Dl_info core;
  if (ruby_bug && dladdr((void *)ruby_bug, &core)) ruby_core_base = core.dli_fbase;
  // The guard test shortens the alarm; CI keeps the 30-second default.
  const char *secs = getenv("NATIVE_ABORT_REPORT_ALARM");
  if (secs && atoi(secs) > 0) report_alarm = (unsigned)atoi(secs);
  // Load libgcc_s's unwinder now, while the heap is sound, not inside the handler.
  void *warm[1];
  backtrace(warm, 1);

  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = on_abort;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGABRT, &sa, NULL);
}
