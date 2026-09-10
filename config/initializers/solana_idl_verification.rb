# Boot-time IDL hash verification (audit Tier 3 #22).
# In production only — verifies the committed turf_vault IDL hasn't drifted
# from the on-chain program. Raises before the web server accepts connections.
#
# Skip locally + in tests because:
#   - dev DBs often run against an older IDL during iteration
#   - tests stub Solana calls anyway (see test_solana_stubs.rb)
#
# 2026-05-23 (audit H4): the old `SKIP_IDL_VERIFICATION=true` escape hatch
# was removed in production. A leaked Heroku API token + `heroku config:set
# SKIP_IDL_VERIFICATION=true` would otherwise let an attacker swap in a
# poisoned IDL whose account orderings differ from the deployed program,
# causing every Phantom-signed TX to write to attacker-controlled
# accounts. The escape hatch survives only in dev/test, where it never
# protected anything meaningful.
#
# If a controlled mid-upgrade requires temporarily bypassing the check in
# production, the deployer must:
#   1. Set `EXPECTED_IDL_HASH` to the NEW IDL's hash (don't unset it)
#   2. Commit the new IDL JSON
#   3. Deploy
# The whole point is that the env var should never be the kill switch.
#
# Skip during Heroku slug compilation: `assets:precompile` loads the Rails
# environment with SECRET_KEY_BASE_DUMMY=1.
#
# The reason this comment used to give — that Heroku's build phase does NOT
# expose user-set config vars — is FALSE, and Solana::Config disproves it.
# PROGRAM_ID (and now NETWORK and RPC_URL) RAISE when unset in production, and
# they are evaluated by the SAME production eager load that `assets:precompile`
# triggers. That raise has been in place since 2026-05-19 and
# turf-monster-mainnet was on release v187 as of 2026-08-20; if the build could
# not read SOLANA_PROGRAM_ID, every one of those builds would have failed at
# compile.
#
# The skip is kept on its real merits. IDL verification is a RELEASE-time
# invariant about what is deployed on-chain, and the build is the wrong place to
# fail it: bin/deploy widens EXPECTED_IDL_HASH to {old,new} BEFORE it pushes, so
# a build-time check would pass anyway, and keeping the failure in the release
# phase means a bad pin rolls back cleanly instead of dying as a slug-compile
# error. Verification still runs at release-phase + web-dyno boot.
if Rails.env.production? && !ENV["SECRET_KEY_BASE_DUMMY"]
  if ENV["SKIP_IDL_VERIFICATION"].present?
    raise <<~MSG
      SKIP_IDL_VERIFICATION is set in production — refusing to boot.

      Audit H4 (2026-05-23) removed this escape hatch. To deploy a new IDL,
      set EXPECTED_IDL_HASH to the new hash and commit the IDL JSON instead.

      heroku config:unset SKIP_IDL_VERIFICATION --app turf-monster-mainnet
    MSG
  end

  Rails.application.config.after_initialize do
    Solana::Config.verify_idl!
  rescue Solana::Config::IdlMismatchError => e
    Rails.logger.error(e.message)
    raise
  end
end
