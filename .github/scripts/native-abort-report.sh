#!/bin/sh
# Build the native-abort-report shim and preload it for every LATER step of this job.
# Why it exists: .github/scripts/native-abort-report.c (the head comment).
# Guard: test/lib/ci_native_abort_report_test.rb.
#
# A build failure fails the step: a silent skip would leave the next abort as mute
# as the one in run 42745469708. The shim installs itself only in Ruby processes.
set -eu

src="$(dirname "$0")/native-abort-report.c"
out="${RUNNER_TEMP:-/tmp}/native-abort-report.so"

cc -shared -fPIC -O2 -Wall -Werror -o "$out" "$src"
echo "native-abort-report: built $out"

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "LD_PRELOAD=$out" >> "$GITHUB_ENV"
  echo "native-abort-report: LD_PRELOAD exported for the later steps"
fi
