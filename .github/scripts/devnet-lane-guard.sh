#!/usr/bin/env bash
#
# Fail the build when turf-monster's on-chain E2E lane has stopped running.
#
# WHY THIS EXISTS, AND WHY IT IS A *BUILD* FAILURE. On 2026-08-20 the 18
# @devnet specs in e2e/devnet-smoke.spec.js were running NOWHERE, and had been
# for at least twelve consecutive days:
#
#   · ci.yml's playwright job excludes them (--grep-invert "@devnet").
#     (SEVENTEEN, not the eighteen this gap was first reported as: `grep -c`
#     over the spec file counts a comment on line 95 as well as the 17 tests.
#     `npx playwright test --project=devnet --list` is the honest count.)
#   · devnet-nightly.yml — the only lane that would run them — gated the whole
#     JOB on `if: vars.DEVNET_NIGHTLY_ENABLED == 'true'`, so every scheduled
#     run completed `skipped` (runs 31248719068 … 32233040903, 2026-08-08
#     through 2026-08-19; a hand dispatch on 2026-08-20, run 32336618549, did
#     the same in one second).
#   · config/feature_shapes.yml dropped the e2e_onchain tier on 2026-07-13
#     BECAUSE no lane ran it, so the DevOps cycle stopped asking for it too.
#
# Nothing was broken. Nothing went red. The coverage simply evaporated, and it
# was found by a human reading a workflow file — which is the failure mode this
# script exists to make impossible. A grey `skipped` in the Actions tab is not a
# signal; nobody subscribes to the absence of an event. The only channel that
# reliably reaches a person here is the one they already stare at: their own PR.
#
# WHAT THIS ASSERTS — one rule, deliberately: the newest Devnet Nightly run must
# have concluded `success`, having actually EXECUTED the suite step, within
# MAX_AGE_DAYS. Everything the lane can do wrong collapses into that rule:
#
#   never run / every run skipped   → red   (the 2026-08 disease)
#   switch flipped off              → red   (nightly reddens at once via its own
#                                            preflight; this reddens PR CI after
#                                            the window, so an "off" that is
#                                            never turned back on escalates)
#   failing N+ days running         → red   (a nightly that fails into an empty
#                                            room is the same silence wearing a
#                                            different colour)
#   one bad devnet night, next green→ green (transient RPC/faucet noise must not
#                                            hold every unrelated PR hostage)
#
# WHY `success` AND NOT "concluded": treating a red nightly as good enough would
# reproduce the original bug one layer up — a guard that demands evidence and
# then accepts its absence. The N-day window, not a laxer verdict, is what buys
# tolerance for a flaky devnet.
#
# WHY 3 DAYS. Three missed nightlies. One bad night is devnet; two is bad luck;
# three is a lane nobody is minding. Short enough that the gap found on
# 2026-08-20 would have gone red on 2026-08-11 rather than surviving twelve
# days, long enough that a single 429-storm at 08:00 UTC costs nobody a merge.
#
# WHY IT RE-CHECKS THE STEP AND NOT JUST THE RUN. A run-level `success` is not
# proof the specs ran — a job whose steps all skip still concludes green, which
# is precisely the shape of green this repo keeps getting burned by. So the
# newest successful run is opened and the suite step's OWN conclusion is read.
# SUITE_STEP_NAME must therefore match devnet-nightly.yml byte for byte; if it
# drifts, this script finds zero matching steps and FAILS rather than passing
# over an empty set. test/lib/devnet_lane_guard_test.rb pins the pair together
# so the drift is caught locally, before it ever reaches a runner.
#
# ONE KNOWN WEAKNESS, stated rather than hidden: this counts a successful run on
# ANY ref, not only the default branch. The scheduled nightly always runs on the
# default branch, so in normal operation the distinction never arises — but a
# hand dispatch from a feature branch does satisfy the guard. That is deliberate
# and it is the bootstrap: the PR that first introduced this guard could not
# otherwise have gone green, because no qualifying run could exist until after
# it merged. If this lane ever needs hardening, `head_branch` is the field.
#
# Requires: gh (preinstalled on GitHub runners), GH_TOKEN with `actions: read`.

set -euo pipefail

REPO="${GH_REPO:-${GITHUB_REPOSITORY:-}}"
WORKFLOW_FILE="devnet-nightly.yml"
SUITE_STEP_NAME="Run the @devnet Playwright suite"
# Overridable so the guard is exercisable by hand; ci.yml must NOT set it, and
# test/lib/devnet_lane_guard_test.rb asserts that the live lane runs on the
# default. A dial CI can quietly turn down is the disease, not the cure.
MAX_AGE_DAYS="${DEVNET_LANE_MAX_AGE_DAYS:-3}"

if [ -z "$REPO" ]; then
  echo "devnet-lane-guard: no repository — set GH_REPO or GITHUB_REPOSITORY." >&2
  exit 2
fi

SETTINGS_URL="https://github.com/${REPO}/settings/variables/actions"
ACTIONS_URL="https://github.com/${REPO}/actions/workflows/${WORKFLOW_FILE}"

note() { echo "$@"; [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$@" >> "$GITHUB_STEP_SUMMARY"; return 0; }

# Newest successful run. The list endpoint returns newest-first; 50 is far more
# than the window can hold at one run per day, so a `first` over it cannot miss
# a run that is actually inside the window.
# Raw body out of gh, filtered by the local jq. `gh api --jq` runs an EMBEDDED
# jq that takes the filter and nothing else — it has no `--arg` — and the step
# lookup below needs one. Keeping both queries on the same local jq keeps the
# two filters written in one dialect, and lets the test drive them for real
# against canned API bodies instead of stubbing their results.
runs_body="$(gh api "/repos/${REPO}/actions/workflows/${WORKFLOW_FILE}/runs?per_page=50" 2>/dev/null || true)"
run_json="$(printf '%s' "$runs_body" | jq -c '[.workflow_runs[]? | select(.conclusion == "success")] | first // empty' 2>/dev/null || true)"

if [ -z "$run_json" ]; then
  note "### :x: The @devnet lane has never completed a run"
  note ""
  note "No **successful** \`Devnet Nightly\` run exists in the last 50 runs of ${WORKFLOW_FILE}."
  note "turf-monster's 17 on-chain E2E specs (\`e2e/devnet-smoke.spec.js\`) are covered NOWHERE."
  note ""
  note "Unblock it: set \`DEVNET_NIGHTLY_ENABLED=true\`, \`SOLANA_BOT_KEY\` (a funded devnet"
  note "keypair) and \`SOLANA_RPC_URL\` at ${SETTINGS_URL}, then run the lane: ${ACTIONS_URL}"
  exit 1
fi

run_id="$(printf '%s' "$run_json"   | jq -r '.id')"
run_url="$(printf '%s' "$run_json"  | jq -r '.html_url')"
created="$(printf '%s' "$run_json"  | jq -r '.created_at')"
# jq does the clock arithmetic so the script never depends on whether `date` is
# BSD or GNU — the two disagree on -d/-j and the difference has killed scripts
# in this ecosystem before.
age_days="$(printf '%s' "$run_json" | jq -r '((now - (.created_at | fromdateiso8601)) / 86400) | floor')"

# The run said green. Did the SUITE actually run inside it?
jobs_body="$(gh api "/repos/${REPO}/actions/runs/${run_id}/jobs" 2>/dev/null || true)"
step_conclusions="$(printf '%s' "$jobs_body" \
  | jq -r --arg step "$SUITE_STEP_NAME" \
      '[.jobs[]?.steps[]? | select(.name == $step) | .conclusion] | join(",")' 2>/dev/null || true)"

if [ -z "$step_conclusions" ]; then
  note "### :x: The @devnet lane reported green without running the suite"
  note ""
  note "Run [${run_id}](${run_url}) concluded \`success\`, but it contains no step named"
  note "\`${SUITE_STEP_NAME}\`. Either the suite did not run, or that step was renamed in"
  note "\`${WORKFLOW_FILE}\` without updating \`SUITE_STEP_NAME\` in this script."
  exit 1
fi

case ",${step_conclusions}," in
  *",success,"*) : ;;
  *)
    note "### :x: The @devnet suite step did not succeed in the newest green run"
    note ""
    note "Run [${run_id}](${run_url}) concluded \`success\`, but \`${SUITE_STEP_NAME}\` concluded"
    note "\`${step_conclusions}\`. A green run over a suite that did not run is not coverage."
    exit 1
    ;;
esac

if [ "$age_days" -gt "$MAX_AGE_DAYS" ]; then
  note "### :x: The @devnet lane has gone quiet"
  note ""
  note "Newest successful \`Devnet Nightly\`: [${run_id}](${run_url}) — **${age_days} days old**"
  note "(the lane must run at least every ${MAX_AGE_DAYS} days; it is scheduled daily at 08:00 UTC)."
  note ""
  note "turf-monster's on-chain E2E coverage is stale. Check ${ACTIONS_URL} — if the lane is"
  note "switched off, its own preflight names which of \`DEVNET_NIGHTLY_ENABLED\`,"
  note "\`SOLANA_BOT_KEY\` or \`SOLANA_RPC_URL\` is missing (${SETTINGS_URL})."
  exit 1
fi

note "### :white_check_mark: The @devnet lane is live"
note ""
note "Newest successful \`Devnet Nightly\`: [${run_id}](${run_url}) — ${age_days} day(s) old,"
note "\`${SUITE_STEP_NAME}\` concluded \`success\`. Window: ${MAX_AGE_DAYS} days."
