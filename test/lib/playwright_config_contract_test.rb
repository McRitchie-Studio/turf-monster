require "test_helper"

# Contract: the e2e webServer boot budget must cover db:test:prepare + the
# e2e seed (which caches the full NFL 2026 team totals since 2026-07) + rails
# server boot on a slow CI runner. The prior 30s budget was marginal and
# red-flaked playwright shard 1 twice in two days (runs 29692136014 and
# 29720145697), both timing out directly after the NFL cache seed line. Guard
# the floor so it cannot quietly regress.
class PlaywrightConfigContractTest < ActiveSupport::TestCase
  CONFIG_PATH = Rails.root.join("playwright.config.js")

  test "webServer timeout floor covers the seeded boot" do
    config = CONFIG_PATH.read
    web_server_index = config.index("webServer:")
    assert web_server_index, "webServer block not found in playwright.config.js"

    # First timeout AFTER the webServer key — the file also carries global
    # per-test and expect timeouts before it, which must not satisfy this.
    timeout = config[web_server_index..][/timeout:\s*([\d_]+)/, 1]

    assert timeout, "webServer timeout not found in playwright.config.js"
    assert_operator timeout.delete("_").to_i, :>=, 120_000
  end

  # THE REDUCED-MOTION SPELLING, PINNED.
  #
  # This is a BACKSTOP, not the proof — and the distinction is the whole finding
  # of /tasks/make-reduced-motion-reach-specs. `reducedMotion: "reduce"` sat in
  # this config for months while `matchMedia("(prefers-reduced-motion: reduce)")
  # .matches` was FALSE in every spec, so a test that greps for the string would
  # have been GREEN throughout the bug. Measured on Playwright 1.58.2:
  #
  #     use: { reducedMotion: ... }              -> matches FALSE
  #     projects[].use: { reducedMotion: ... }   -> matches FALSE
  #     use: { contextOptions: { reducedMotion } } -> matches TRUE
  #
  # The behavioral proof is e2e/reduced_motion.spec.js, which asks a real page
  # under the real runner. What THIS test adds is a cheap, unit-tier tripwire on
  # the one edit most likely to undo it: someone "tidying" the nested option back
  # to the flat key, which reads identical and silently does nothing. That edit
  # would only be caught by the playwright lane otherwise — a much slower, much
  # more expensive place to find out.
  test "reducedMotion is set where it actually takes effect" do
    config = CONFIG_PATH.read

    assert_match(
      /contextOptions:\s*\{[^}]*reducedMotion:\s*"reduce"/,
      config,
      "playwright.config.js must set reducedMotion inside `use.contextOptions`. " \
      "The bare `use.reducedMotion` key is INERT on Playwright 1.58.2 — it reads " \
      "as the same setting and never reaches the page."
    )

    # And NOT as the flat key, which is the inert spelling. Scoped to a line that
    # is not a comment, so this file's own explanation of the trap (and the long
    # note in playwright.config.js) does not trip it.
    # The effective form is written `contextOptions: { reducedMotion: "reduce" }`,
    # so the key is never the first thing on its line. The inert form always is.
    inert = config.lines.reject { |l| l.strip.start_with?("//", "*", "/*") }
                  .grep(/^\s*reducedMotion:/)
    assert_empty inert,
      "found a bare `reducedMotion:` key in playwright.config.js: #{inert.inspect}. " \
      "That spelling does nothing; nest it under `contextOptions`."
  end
end
