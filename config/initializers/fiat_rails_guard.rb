# Live production refuses to boot with ENABLE_FIAT_RAILS on.
#
# The fiat rails (Stripe, PayPal/Venmo, Coinflow, Aeropay) are parked: their
# code stays in the tree for a later season, and FiatRailsParked lists every
# route, webhook, job and view the flag opens. Switching them on in live
# production takes money from players, so it must be a deliberate act: a boot
# carrying the flag raises AppFlags::FiatRailsRefused, the dyno crashes, and a
# Heroku build fails at assets:precompile, which leaves the running release up.
#
# The one way through is FIAT_RAILS_OVERRIDE, set to the reason. The boot then
# succeeds, logs at ERROR with that reason and reports to Sentry. The un-park
# checklist is in docs/FIAT_RAILS.md.
#
# "Live production" is AppFlags.live_production?: Rails production without
# QA_ENV. QA, development and test may run the flag without an override, so a
# provider sandbox can be rehearsed before production.
Rails.application.config.after_initialize do
  if AppFlags.live_production? && AppFlags.fiat_rails?
    override = AppFlags.fiat_rails_override

    unless override
      raise AppFlags::FiatRailsRefused,
        "ENABLE_FIAT_RAILS is set on live production, which would open the " \
        "parked Stripe, PayPal, Coinflow and Aeropay rails. Unset it, or set " \
        "FIAT_RAILS_OVERRIDE to the reason (docs/FIAT_RAILS.md)."
    end

    message = "ENABLE_FIAT_RAILS is enabled in production under " \
              "FIAT_RAILS_OVERRIDE=#{override.inspect}: the fiat payment " \
              "routes, webhooks and jobs are live (docs/FIAT_RAILS.md)."

    Rails.logger.error(message)
    Sentry.capture_message(message, level: :warning) if defined?(Sentry) && Sentry.initialized?
  end
end
