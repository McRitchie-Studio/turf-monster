# MAY bin/deploy SKIP ITS LOCAL TEST RUN?
#
# Only when the release conductor has read GitHub CI GREEN for exactly the commit
# being deployed. The conductor (mcritchie-studio bin/release.rb, test_gate) reads
# CI's settled verdict for the SHA it deploys, the frozen SHA or its re-lock
# commit, and only after a green read does it append `--ci-verified=<that sha>`
# (config/release_repos.yml, turf-monster `prod_deploy.ci_verified_arg`). Before
# this, bin/deploy re-ran `bin/rails test` (about 20 minutes) on a SHA CI had
# already passed.
#
# The rule here is the deploy's own half of that contract, and it fails closed:
#
#   no flag              -> :run    run the suite, exactly as before
#   flag == HEAD (full)  -> :skip   CI already passed this exact tree
#   anything else        -> :refuse a malformed SHA, an abbreviated one, or one
#                                   that is not HEAD. That is a caller bug, and a
#                                   deploy must not guess which tree CI vouched
#                                   for. Nothing has been changed yet when this
#                                   refuses.
#
# Every other pre-deploy check (clean tree, IDL hash pin, Stripe live mode,
# signer isolation), the confirmation, the smoke and the rollback still run.
#
# Plain Ruby, no Rails boot, so bin/deploy can call it as a script:
#   ruby lib/deploy/ci_verified.rb --head <sha> --verified <sha-or-empty>
# prints one line and exits 0 (:skip), 10 (:run) or 3 (:refuse).
module Deploy
  module CiVerified
    FULL_SHA = /\A[0-9a-f]{40}\z/
    EXIT = { skip: 0, run: 10, refuse: 3 }.freeze

    module_function

    # [verdict, message]
    def decide(head:, verified:)
      claimed = verified.to_s.strip.downcase
      return [:run, "no --ci-verified given — running the local suite"] if claimed.empty?

      current = head.to_s.strip.downcase
      unless claimed.match?(FULL_SHA)
        return [:refuse, "--ci-verified=#{verified} is not a full 40-character SHA — refusing; nothing was changed"]
      end
      unless claimed == current
        return [:refuse, "--ci-verified names #{claimed[0, 12]} but HEAD is #{current[0, 12]} — CI vouched for " \
                         "another tree; refusing, nothing was changed"]
      end

      [:skip, "GitHub CI read GREEN for #{claimed[0, 12]} (HEAD) by the release conductor — skipping the local " \
              "suite CI already ran"]
    end

    def main(argv)
      head = value(argv, "--head")
      verified = value(argv, "--verified")
      verdict, message = decide(head: head, verified: verified)
      puts message
      EXIT.fetch(verdict)
    end

    def value(argv, flag)
      i = argv.index(flag)
      i ? argv[i + 1].to_s : ""
    end
  end
end

exit(Deploy::CiVerified.main(ARGV)) if $PROGRAM_NAME == __FILE__
