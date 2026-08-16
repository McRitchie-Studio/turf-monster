#!/usr/bin/env bash
#
# Wait for the locally published gem versions pinned in Gemfile.lock to be
# visible on the RubyGems index THIS RUNNER resolves through, before anything
# tries to install them.
#
# WHY THIS EXISTS. `bin/release prepare` publishes a gem, commits the consumer
# `Gemfile.lock` bump onto `origin/release`, and that commit triggers CI seconds
# later. A job whose bundler cache misses then goes to the network for a version
# published moments ago — and RubyGems does not serve a new version from every
# CDN edge at once. `bundle install` dies with exit code 7 and the actively
# misleading claim that the author "has removed" a version that is perfectly
# live.
#
# It fired on BOTH releases of 2026-08-16, in different repos and different jobs:
#   · rel-20260816-92c013 — mcritchie-studio `lint`   @ abfdcf8 (run 31928197053)
#   · rel-20260816-53fa78 — turf-monster    `scan_js` @ 5302c71 (run 31931534886)
# Each time the pre-QA gate read the red and ABORTED the sweep, after the
# promote, publish, tag and lock bump had all already succeeded. Each time a
# plain re-run of the failed job went green on the SAME SHA with no code change.
# The tell: sibling jobs on the same commit bundled fine — they restored a usable
# cache and never hit the network at all.
#
# WHY IT RUNS HERE, ON THE RUNNER. The sweep already waits for the compact index
# before it bumps consumer locks, and that wait passed both times. A check from
# the conductor's machine proves what the CONDUCTOR's CDN edge serves; it cannot
# speak for the edge a GitHub runner will hit minutes later. This polls the same
# host, from the same network, seconds before the install — which is the only
# place the question can actually be answered.
#
# FAIL-SOFT BY DESIGN — read this before adding an `exit 1`. This script NEVER
# fails the job. If a version never appears it warns and returns 0, leaving
# exactly today's behaviour in place. That property is what keeps it off the
# critical path: it can only ever turn a red green, never the reverse, so it
# cannot become a new way for CI to break. It is also why it needs no
# `continue-on-error` anywhere — which matters, because
# test/lib/ci_workflow_triggers_test.rb forbids that key outright, on the
# grounds that a lane which runs, fails, and reports green is the same lie as a
# lane that runs nothing.
#
set -uo pipefail

GEMS=${AWAIT_GEMS:-"studio-engine solana-studio"}
LOCK=${AWAIT_LOCK:-Gemfile.lock}
TIMEOUT=${AWAIT_TIMEOUT:-120}
INTERVAL=${AWAIT_INTERVAL:-10}

if [ ! -f "$LOCK" ]; then
  echo "::debug::$LOCK not found — nothing to await"
  exit 0
fi

deadline=$(( $(date +%s) + TIMEOUT ))

for gem in $GEMS; do
  # The lockfile spells a resolved gem as "    studio-engine (0.55.0)".
  version=$(sed -n "s/^ *${gem} (\([0-9][^)]*\))\$/\1/p" "$LOCK" | head -1)

  if [ -z "$version" ]; then
    echo "::debug::${gem} is not pinned in ${LOCK} — skipping"
    continue
  fi

  # Escape the dots so 0.55.0 cannot match 0x55y0.
  pattern="^$(printf '%s' "$version" | sed 's/\./\\./g') "

  while :; do
    if curl -fsS --max-time 15 "https://index.rubygems.org/info/${gem}" 2>/dev/null \
      | grep -qE "$pattern"; then
      echo "${gem} ${version} is visible on the index this runner resolves through"
      break
    fi

    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "::warning::${gem} ${version} still not visible after ${TIMEOUT}s — continuing anyway; bundle install may hit the propagation race"
      break
    fi

    echo "awaiting ${gem} ${version} on the RubyGems index…"
    sleep "$INTERVAL"
  done
done

exit 0
