# Announce — loudly — when ENABLE_TEST_SCAFFOLDING is on in production.
#
# The flag unlocks the $1 "micro" contest tier and the $5 / 3-token bundle
# (see AppFlags.test_scaffolding? and the TEST_PACK_IDS / TEST_FORMAT_KEYS
# constants in StripePurchase / Contest). Off by default everywhere.
#
# This used to `raise` on boot, which made a production deploy carrying the flag
# crash. That was deliberate — the $5/3-token pack prices an entry token at
# $1.67 against a real $19 — but it also made the $1 micro tier, the flag's other
# half, unreachable on production at all. The operator's call (2026-08-27) is
# that a real-money rehearsal on production is worth more than the hard stop, so
# the boot now SUCCEEDS.
#
# What did not change: the flag is still off unless someone sets it, and while it
# IS set production really is selling $1.67 entry tokens to anyone who reaches the
# buy UI. So the signal survives the guard — every boot in that state logs at
# ERROR and reports to Sentry, and the flag is meant to be unset when the test
# window closes:
#   heroku config:unset ENABLE_TEST_SCAFFOLDING --app turf-monster-mainnet
Rails.application.config.after_initialize do
  if Rails.env.production? && AppFlags.test_scaffolding?
    message = "ENABLE_TEST_SCAFFOLDING is enabled in production: the $1 micro " \
              "contest tier AND the $5 / 3-token pack ($1.67 per entry token vs " \
              "$19) are both live. Unset it when the test window closes " \
              "(heroku config:unset ENABLE_TEST_SCAFFOLDING --app turf-monster-mainnet)."

    Rails.logger.error(message)
    Sentry.capture_message(message, level: :warning) if defined?(Sentry) && Sentry.initialized?
  end
end
