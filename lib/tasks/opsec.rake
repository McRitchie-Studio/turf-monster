# opsec:signing_key_isolation — refuse a prod deploy while QA signs as production.
#
# Asserts that `turf-monster-qa` and `turf-monster-mainnet` do NOT share the
# same `SOLANA_ADMIN_KEY` (the Alex Bot server signer). Measured shared, byte
# for byte, on 2026-09-08.
#
# WHERE IT RUNS — and where it does NOT. This task shells out to the Heroku CLI
# for BOTH apps, so it only works where a Heroku session exists: the operator's
# machine, from `bin/deploy`'s pre-flight, on every turf-monster production
# deploy. It does NOT run in CI (no Heroku auth, neither secret present) and it
# cannot run on a dyno (a dyno sees only its own ENV). CI covers the LOGIC —
# test/lib/signing_key_isolation_test.rb and
# test/tasks/opsec_signing_key_isolation_test.rb drive every verdict against an
# injected reader — never the live comparison. Do not write it up as CI-covered.
#
# Fails closed: a value that is absent, empty, or unreadable on either side is
# INDETERMINATE, which exits non-zero. Absence is not isolation.
#
#   bin/rails opsec:signing_key_isolation
namespace :opsec do
  # NB: the description is a literal. `desc` is evaluated when rake LOADS this
  # file, which happens before the `:environment` prerequisite has booted
  # Zeitwerk, so naming the constant here would NameError on `rails -T`.
  desc "Assert QA and production do not share SOLANA_ADMIN_KEY"
  task signing_key_isolation: :environment do
    guard = TurfMonster::SigningKeyIsolation.probe(
      reader: TurfMonster::SigningKeyIsolation::HerokuReader.new
    )

    puts guard.report
    exit(guard.ok? ? 0 : 1)
  end
end
