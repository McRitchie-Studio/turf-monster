# Live production refuses to boot with ENABLE_TEST_SCAFFOLDING on.
#
# The flag unlocks the $1 "micro" contest tier, the $5 / 3-token pack ($1.67 per
# entry token against a real $19) and the contest test actions (jump, simulate,
# fill, reset), which rewrite shared game scores, settle and mint comped entries.
# None of that belongs on live production by accident, so a live-production boot
# carrying the flag raises AppFlags::TestScaffoldingRefused: the dyno crashes and
# a Heroku build fails at assets:precompile, which leaves the running release up.
#
# The one way through is TEST_SCAFFOLDING_OVERRIDE, set to the reason, for the
# real-money rehearsal the micro tier exists for. The boot then succeeds, logs at
# ERROR with that reason and reports to Sentry; unset both vars when the
# rehearsal ends.
#
# "Live production" is AppFlags.live_production?: Rails production without
# QA_ENV. A QA app also boots as Rails production, and QA_ENV is what tells it
# apart, so QA keeps the flag; so do development and test.
Rails.application.config.after_initialize do
  if AppFlags.live_production? && AppFlags.test_scaffolding?
    override = AppFlags.test_scaffolding_override
    exposure = "the $1 micro contest tier, the $5 / 3-token pack ($1.67 per " \
               "entry token vs $19) and the contest test actions"

    unless override
      raise AppFlags::TestScaffoldingRefused,
        "ENABLE_TEST_SCAFFOLDING is set on live production, which would open " \
        "#{exposure}. Unset it, or set TEST_SCAFFOLDING_OVERRIDE to the reason " \
        "for a deliberate rehearsal."
    end

    message = "ENABLE_TEST_SCAFFOLDING is enabled in production under " \
              "TEST_SCAFFOLDING_OVERRIDE=#{override.inspect}: #{exposure} are " \
              "live. Unset both when the rehearsal ends " \
              "(heroku config:unset ENABLE_TEST_SCAFFOLDING TEST_SCAFFOLDING_OVERRIDE)."

    Rails.logger.error(message)
    Sentry.capture_message(message, level: :warning) if defined?(Sentry) && Sentry.initialized?
  end
end
