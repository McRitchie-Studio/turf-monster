# frozen_string_literal: true

require "test_helper"

# THE TWO E2E LANES MUST TURN THE SAME RAILS ON, IN BOTH OF THE PLACES THAT MATTER.
#
# An onramp flag is read by TWO processes for two different reasons, and a run needs both:
#
#   1. THE PLAYWRIGHT PROCESS — disarms `test.skip(process.env.ENABLE_X !== "true", …)`
#      in e2e/financial.spec.js.
#   2. THE RAILS SERVER — renders the rail, because app/views/tokens/buy.html.erb gates on
#      AppFlags.coinflow?/aeropay?, which read the SERVER's ENV.
#
# Set only #1 and the specs drive a page with no rail on it. That is not hypothetical: the
# first cut of run-the-gated-payment-specs did exactly that, and CI COULD NOT SEE IT.
# Playwright builds its webServer's env as {...DEFAULT, ...process.env, ...options.env}, so
# the CI lane inherited #1 by accident and passed, while `npm run test:parallel` — which
# sets PW_BASE_URL, takes the `webServer: undefined` branch and launches its own servers,
# inheriting nothing — went red. A lane that cannot observe its own breakage is the thing
# this file exists to prevent.
#
# The `process.env` block in playwright.config.js is the SOURCE OF TRUTH for which rails
# the e2e stack runs. This test propagates that list to both server-launch paths, so adding
# a third flag to one lane and forgetting the other is RED at the source level rather than
# discovered by whichever lane happens to run next.
class E2eOnrampFlagParityTest < ActiveSupport::TestCase
  PLAYWRIGHT_CONFIG = Rails.root.join("playwright.config.js")
  E2E_PARALLEL      = Rails.root.join("bin/e2e-parallel")

  # `process.env.ENABLE_FOO ||= "true";`
  def onramp_flags
    PLAYWRIGHT_CONFIG.read.scan(/^process\.env\.([A-Z0-9_]+)\s*\|\|=\s*"true";/).flatten
  end

  # The `env: { … }` object on the webServer block.
  def web_server_env_keys
    body = PLAYWRIGHT_CONFIG.read[/^\s*env:\s*\{(.*?)^\s*\},/m, 1]
    refute_nil body, "playwright.config.js no longer has a webServer `env:` block; this guard has gone blind"
    body.scan(/^\s*([A-Z0-9_]+):\s*"/).flatten
  end

  test "unit the playwright process turns at least one onramp rail on" do
    assert_predicate onramp_flags, :any?,
                     "playwright.config.js no longer sets any ENABLE_* rail on process.env. " \
                     "If that is deliberate, delete this file; if it is drift, the payment " \
                     "specs are silently skipping again."
  end

  test "unit every rail the playwright process enables is also named in the webServer env" do
    missing = onramp_flags - web_server_env_keys

    assert_empty missing,
                 "playwright.config.js sets #{missing.join(', ')} on process.env but does not name " \
                 "#{missing.size == 1 ? 'it' : 'them'} in webServer.env. The CI lane would still pass " \
                 "— Playwright spreads ...process.env into the child — but it would be passing by " \
                 "INHERITANCE, which is precisely the accident that hid a red parallel lane. State it."
  end

  # This is the assertion that would have caught the original break.
  test "unit every rails-launching subshell in e2e-parallel exports every onramp rail" do
    lines = E2E_PARALLEL.readlines

    # Each isolated stack is a subshell that exports its own DATABASE_URL and then runs
    # Rails (db:prepare / seed / server). That export is the marker for "a Rails process
    # starts here with a hand-built env".
    launch_indexes = lines.each_index.select { |i| lines[i] =~ /^\s*export\s+DATABASE_URL=/ }

    assert_predicate launch_indexes, :any?,
                     "bin/e2e-parallel no longer exports a per-stack DATABASE_URL; this guard has gone blind"

    launch_indexes.each do |i|
      # The flags ride on the line directly below the database export, in the same subshell.
      window = lines[i, 3].join

      onramp_flags.each do |flag|
        assert_match(/export\s[^\n]*\b#{Regexp.escape(flag)}=true\b/, window,
                     "bin/e2e-parallel:#{i + 1} starts a Rails stack without exporting #{flag}. " \
                     "playwright.config.js turns that rail on for the Playwright process, so the " \
                     "spec's test.skip is disarmed — but this lane's server would not render the " \
                     "rail, and the spec fails on `expect(buyButton).toBeVisible()`. CI cannot " \
                     "catch this: its webServer inherits process.env and this lane does not.")
      end
    end
  end

  test "unit the parallel lane really is the branch that manages no webServer" do
    config = PLAYWRIGHT_CONFIG.read

    # If this stops being true, the exports above are belt-and-braces rather than the only
    # thing standing between this lane and a page with no rails on it — and the comments in
    # both files are wrong.
    assert_match(/webServer:\s*process\.env\.PW_BASE_URL\s*\n?\s*\?\s*undefined/, config,
                 "playwright.config.js no longer skips its webServer when PW_BASE_URL is set. " \
                 "Re-read bin/e2e-parallel's ONRAMP FLAGS note before changing this.")
    assert_match(/^\s*PW_BASE_URL=/, E2E_PARALLEL.read,
                 "bin/e2e-parallel no longer sets PW_BASE_URL; the two lanes may have converged, " \
                 "which would make this whole file stale.")
  end
end
