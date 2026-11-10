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
// processes only (it checks /proc/self/exe; node, Chromium and sh are untouched).
// On abort it writes glibc's own C backtrace (backtrace_symbols_fd: no malloc), then
// calls Ruby's rb_bug(), which prints the full [BUG] report (control frames, the Ruby
// backtrace, the C backtrace, the loaded libraries) and dies by abort() again. The
// handler resets SIGABRT to the default first, so the second abort ends the process
// with the same exit code as before (134). A 30-second SIGALRM is armed first: glibc
// can abort with the arena lock held, and if the report then deadlocks in malloc, the
// process still dies (exit 142) instead of hanging the job.
//
// It changes no allocation and no behaviour before an abort. It is a reporter, not
// a fix. Built and exported by .github/scripts/native-abort-report.sh.
// Guard: test/lib/ci_native_abort_report_test.rb.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <execinfo.h>
#include <signal.h>
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

static void on_abort(int sig) {
  (void)sig;
  signal(SIGABRT, SIG_DFL);
  signal(SIGALRM, SIG_DFL);
  alarm(30);

  say("\n-- native-abort-report: SIGABRT in a Ruby process (glibc or a native "
      "extension called abort()) --\n-- C backtrace at the abort --\n");
  void *frames[96];
  int n = backtrace(frames, 96);
  backtrace_symbols_fd(frames, n, 2);

  rb_bug_fn rb_bug = (rb_bug_fn)dlsym(RTLD_DEFAULT, "rb_bug");
  if (rb_bug) {
    say("-- Ruby's crash report follows --\n");
    rb_bug("native abort (SIGABRT): heap corruption or a native assertion; "
           "see the native-abort-report C backtrace above");
  }
  say("-- native-abort-report: rb_bug not found; re-raising SIGABRT --\n");
  raise(SIGABRT);
}

__attribute__((constructor)) static void native_abort_report_install(void) {
  if (!running_ruby()) return;
  // Load libgcc_s's unwinder now, while the heap is sound, not inside the handler.
  void *warm[1];
  backtrace(warm, 1);

  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = on_abort;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGABRT, &sa, NULL);
}
