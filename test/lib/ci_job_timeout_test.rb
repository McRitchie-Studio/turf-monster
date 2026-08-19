# frozen_string_literal: true

# Guard: EVERY workflow job declares a wall-clock bound.
#
# WHY. A GitHub job with no `timeout-minutes` inherits the platform default of
# SIX HOURS. That is not a bound, it is an absence of one, and the difference is
# not academic — on 2026-08-18 a runner-fleet network incident left jobs sitting
# on "Install packages" and "Install FFmpeg":
#
#   mcritchie-studio  test / playwright (3) / island_animator   1h39m
#   studio-engine     mcritchie_industries suite vs this engine 3h54m
#
# Both had to be CANCELLED BY HAND. That is the sharp part: GitHub refuses
# `gh run rerun` on an incomplete run, so a hang blocks the SANCTIONED SINGLE
# RETRY as well as the run itself. A failed job can be re-run; a hung one cannot.
# One of those hangs stalled a release — the qa-release pre-QA gate credits an
# identical-tree commit to skip a duplicate suite, picked a commit whose second
# run was hung, and waited on a job that would never finish while the candidate's
# own CI was already fully green.
#
# WHY 45 MINUTES, AND WHY UNIFORM. Sized from measured successful durations over
# the last ~12 runs per lane, not guessed:
#
#   scan_ruby / scan_js / lint / e2e_executed_set   0-1 min
#   island_animator                                  0-2 min
#   playwright shards                                2-5 min  (worst success 17)
#   test                                             3-10 min
#
# 45 is ~4.5x the slowest routine lane and ~2.6x the worst observed SUCCESS,
# while catching both hangs with room to spare. Tightness is NOT the goal here:
# a bound that bites a legitimately slow run manufactures exactly the false red
# this repo already pays for elsewhere. The goal is that "hangs forever" becomes
# "fails", which any bound well under six hours achieves. One number, uniform, so
# there is nothing per-lane to drift.
#
# ASSERTED POSITIVELY over every workflow file, rather than listing today's jobs:
# a lane added tomorrow fails here without anyone remembering to enrol it.
require "minitest/autorun"
require "yaml"

class CiJobTimeoutTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  WORKFLOW_GLOB = File.join(ROOT, ".github/workflows/*.yml")
  CEILING = 120 # a "bound" of six hours is the absence this guard exists to remove

  def workflows
    paths = Dir[WORKFLOW_GLOB].sort
    refute_empty paths, "no workflows at #{WORKFLOW_GLOB} — this guard is looking in the wrong place"
    paths
  end

  def test_every_job_declares_a_wall_clock_bound
    unbounded = []
    checked = 0

    workflows.each do |path|
      jobs = (YAML.load_file(path, aliases: true) || {})["jobs"] || {}
      jobs.each do |name, job|
        next unless job.is_a?(Hash)

        checked += 1
        bound = job["timeout-minutes"]
        unbounded << "#{File.basename(path)} :: #{name}" if bound.nil?
      end
    end

    assert_empty unbounded,
                 "these jobs declare no `timeout-minutes`, so they inherit GitHub's SIX HOUR default — " \
                 "a hang there never fails, and an incomplete run cannot be re-run:\n  " +
                 unbounded.join("\n  ")

    # Vacuity guard: green must mean "every job checked", never "no jobs found".
    assert_operator checked, :>=, 1,
                    "found no jobs in #{WORKFLOW_GLOB} — the workflows moved and this guard now asserts nothing"
  end

  def test_no_bound_is_so_large_it_is_not_a_bound
    too_large = []

    workflows.each do |path|
      jobs = (YAML.load_file(path, aliases: true) || {})["jobs"] || {}
      jobs.each do |name, job|
        next unless job.is_a?(Hash)

        bound = job["timeout-minutes"]
        too_large << "#{File.basename(path)} :: #{name} (#{bound}m)" if bound.is_a?(Numeric) && bound > CEILING
      end
    end

    assert_empty too_large,
                 "a bound above #{CEILING} minutes is not a bound — the hangs this guards against ran " \
                 "99 and 234 minutes, so a ceiling that generous would have caught neither:\n  " +
                 too_large.join("\n  ")
  end
end
