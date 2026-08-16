#!/usr/bin/env bash
#
# Wait for the locally published gem versions pinned in Gemfile.lock to appear
# on the RubyGems `/versions` index THIS RUNNER resolves through, before
# anything tries to install them.
#
# WHICH FILE, AND WHY IT IS THIS ONE. The compact index has two files that
# matter here. `/info/<gem>` lists each version's dependencies. `/versions` is
# the master list, one line per publish: `<gem> <version> <md5>`, where the md5
# is a checksum OF THAT GEM'S `/info` FILE.
#
# The two files split the job, and getting the split backwards is easy — an
# earlier draft of this script did (verified against bundler 2.5.23, the version
# both lockfiles pin):
#
#   · `/info/<gem>` SUPPLIES THE VERSIONS the resolver enumerates.
#     `fetcher/compact_index.rb:30-47` → `compact_index_client.info(name)` →
#     `parser.rb:43` parses the /info body. The "can no longer be found" raise
#     is `definition.rb:594`. `Parser#versions` is never called on this path.
#   · `/versions` GATES WHETHER /info IS RE-FETCHED. Its third field is an md5
#     of that gem's /info file (`parser.rb:53-57`), and `cache.rb:29-38` skips
#     the network entirely when the local /info already matches it.
#
# So a fresh `/versions` is NECESSARY BUT NOT SUFFICIENT: confirming it and then
# skipping /info leaves the resolver reading a file nobody checked. This script
# therefore confirms BOTH, and never breaks on /versions alone.
#
# SIGPIPE, and why every read here uses a command substitution rather than a
# pipe: `curl … | grep -q` looks right and is a false-negative generator. `grep
# -q` exits on its FIRST match, curl then dies of EPIPE, and under `pipefail`
# that non-zero status becomes the pipeline's — so a genuine hit reads as a
# miss. MEASURED against the live index: a match early in the tail returned
# pipeline status 56 (curl write error) while the same query for the LAST line
# returned 0. The bug is invisible for a just-published version, which sits at
# the very end and lets curl finish writing — i.e. it hides in exactly the case
# this script is written for, and bites every other one.
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
# How much of the /versions tail to read. The file is append-only, so a version
# published seconds ago sits at the very end. MEASURED 2026-08-16: the whole file
# is 23,157,880 bytes and a 256KiB tail reached back ~4 hours of RubyGems publish
# volume — far more margin than this script needs, at ~1% of the transfer.
TAIL_BYTES=${AWAIT_TAIL_BYTES:-262144}

# Every value below is used in arithmetic or as a curl argument. A non-numeric
# override would otherwise fail mid-flight — and this script must never be the
# reason a job goes red — so fall back to the defaults instead of dying.
case $TIMEOUT in ''|*[!0-9]*) TIMEOUT=120 ;; esac
case $INTERVAL in ''|*[!0-9]*) INTERVAL=10 ;; esac
case $TAIL_BYTES in ''|*[!0-9]*) TAIL_BYTES=262144 ;; esac

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

  # A /versions line is "<gem> <version> <md5-of-that-gems-info-file>". Anchor
  # both ends of the version with the surrounding spaces: without the TRAILING
  # space, "0.5.1 " would also match the line for 0.5.10 — studio-engine ships
  # both. Dots are escaped so they cannot match an arbitrary character.
  pattern="^${gem} $(printf '%s' "$version" | sed 's/\./\\./g') "

  # `/info/<gem>` lists a version as "<version> <deps>|<checksums>".
  info_pattern="^$(printf '%s' "$version" | sed 's/\./\\./g') "

  # `/info` is NECESSARY on every path, so it is never skipped; `/versions` is
  # the freshness gate on top of it. Both are read with the substitution OUTSIDE
  # the pipeline — see the SIGPIPE note in the header. `grep -c` counts instead
  # of short-circuiting, and its own non-zero exit on "no match" is absorbed by
  # the `|| true` so `pipefail` has nothing to propagate.
  seen_info_only=0

  while :; do
    versions_tail=$(curl -fsS --max-time 20 --range "-${TAIL_BYTES}" \
                      "https://index.rubygems.org/versions" 2>/dev/null || true)
    info_body=$(curl -fsS --max-time 20 \
                  "https://index.rubygems.org/info/${gem}" 2>/dev/null || true)

    on_versions=$(printf '%s\n' "$versions_tail" | grep -cE "$pattern" || true)
    on_info=$(printf '%s\n' "$info_body" | grep -cE "$info_pattern" || true)

    # BOTH fresh — the fully-propagated case, and the one a just-published
    # version reaches within seconds.
    if [ "${on_versions:-0}" -gt 0 ] && [ "${on_info:-0}" -gt 0 ]; then
      echo "${gem} ${version} is on /versions AND /info — this edge is fully caught up"
      break
    fi

    # /info alone. This is EXPECTED for any pin older than the tail window: its
    # /versions line exists, just further back than the range we read. It is
    # also what a stale-/versions edge looks like for a fresh publish, and the
    # two are indistinguishable from here — so give /versions a short grace to
    # catch up, then proceed rather than burn the whole timeout on an old pin
    # (measured: studio-engine 0.54.1 otherwise waits the full TIMEOUT in every
    # job). Proceeding is safe on a cold bundler cache, which is the case that
    # fails: with no local /info to compare against, bundler fetches /info and
    # sees the version regardless of what /versions says.
    if [ "${on_info:-0}" -gt 0 ]; then
      seen_info_only=$(( seen_info_only + 1 ))
      if [ "$seen_info_only" -ge 2 ] || [ "$(date +%s)" -ge "$deadline" ]; then
        echo "${gem} ${version} is on /info (the list the resolver enumerates); not in the /versions tail window — proceeding"
        break
      fi
    fi

    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "::warning::${gem} ${version} is not on /info after ${TIMEOUT}s — continuing anyway; bundle install may hit the propagation race"
      break
    fi

    echo "awaiting ${gem} ${version} on the RubyGems index…"
    sleep "$INTERVAL"
  done
done

exit 0
