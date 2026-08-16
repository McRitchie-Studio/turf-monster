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
# Bundler reads `/versions` for BOTH of its decisions: which versions exist (the
# list whose absence produces "can no longer be found"), and whether its cached
# `/info/<gem>` is stale (by comparing that md5). So a stale `/versions` at an
# edge does two things at once — it hides the version from the resolver AND it
# makes bundler trust its cached `/info`, so it never re-fetches the very file a
# freshness check on `/info` would have looked at.
#
# The first version of this script polled `/info/<gem>`. That is a correlated
# proxy — the two files are published together — but it is not the condition
# bundler evaluates, and it can read fresh while `/versions` is still stale.
# This version asks the question bundler actually asks.
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

  while :; do
    # 1. The TAIL of /versions — the authoritative list, cheaply. `curl --range
    #    -N` sends `Range: bytes=-N` and the index answers 206 with the last N
    #    bytes. A server that ignores the range answers 200 with the whole file,
    #    which still greps correctly — just expensively — so this degrades to
    #    slow, never to wrong. A version published moments ago is here.
    if curl -fsS --max-time 20 --range "-${TAIL_BYTES}" \
         "https://index.rubygems.org/versions" 2>/dev/null \
      | grep -qE "$pattern"; then
      echo "${gem} ${version} is on /versions — the list bundler's resolver is built from"
      break
    fi

    # 2. Not in the tail is AMBIGUOUS, and getting this wrong costs the whole
    #    timeout in every job. It means either (a) the version is OLD, published
    #    further back than the tail window, and therefore long since propagated
    #    everywhere — or (b) it is brand new and this edge has not caught up.
    #    `/info/<gem>` separates them: an old version is listed there, while a
    #    version too new for a stale edge is missing from BOTH files, since
    #    /info never leads /versions. So a hit here means "old and fine, do not
    #    wait", and only a miss in both is a genuine not-yet-propagated version.
    #    Without this branch, every pin older than the tail window would burn
    #    the full timeout on every job — measured against studio-engine 0.54.1.
    if curl -fsS --max-time 20 "https://index.rubygems.org/info/${gem}" 2>/dev/null \
      | grep -qE "$info_pattern"; then
      echo "${gem} ${version} predates the /versions tail window and is listed on /info — already propagated"
      break
    fi

    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "::warning::${gem} ${version} is on neither /versions nor /info after ${TIMEOUT}s — continuing anyway; bundle install may hit the propagation race"
      break
    fi

    echo "awaiting ${gem} ${version} on the RubyGems index…"
    sleep "$INTERVAL"
  done
done

exit 0
