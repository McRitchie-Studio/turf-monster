require "test_helper"

# [component] NO SIGNING VIEW MAY DEREFERENCE detect() DIRECTLY.
#
# The bug this change fixed was not one bad line — it was the same bad line in
# six places, each written independently, each correct-looking. Fixing six call
# sites without pinning the shape leaves the seventh free to be written the same
# way tomorrow, and it will fail identically: `null is not an object
# (evaluating 'provider.connect')` in a modal, on a phone, with no test red.
#
# So this asserts the INVARIANT rather than the six edits. A view that reaches
# for a wallet must go through requireProvider(), which answers a missing wallet
# with advice the device can act on.
#
# WHAT THIS TEST CANNOT DO, stated so nobody mistakes it for more: it reads
# source, so it proves a CALL SHAPE, not behaviour. The behaviour is owned by
# test/lib/wallet_require_provider_js_test.rb (the copy rules),
# test/integration/wallet_stub_parity_test.rb (stub and module agree) and
# e2e/wallet_require_provider.spec.js (the module actually arrives). This one
# exists to stop the SEVENTH call site, which none of those would notice.
class WalletGuardInvariantTest < ActiveSupport::TestCase
  VIEWS = Rails.root.join("app/views")

  # The sign-in picker is the one deliberate exception, and it is exempt for a
  # reason rather than by oversight: solanaConnectAndVerify picks a provider BY
  # NAME from the picker the user just chose from, and already renders its own
  # failure through that modal. It is also the one flow that currently works on
  # mobile (via the Phantom deeplink), so routing it through this guard would
  # risk the only thing phones can do today.
  EXEMPT = ["app/views/layouts/application.html.erb"].freeze

  # Hoisted so the vacuity test below can exercise the PATTERN itself.
  DEREFERENCE_SHAPE = /=\s*(?:window\.)?walletProvider\s*&&\s*(?:window\.)?walletProvider\.detect\(\)|=\s*(?:window\.)?walletProvider\.detect\(\)/

  def offending_lines
    Dir.glob(VIEWS.join("**/*.erb")).flat_map do |path|
      rel = Pathname.new(path).relative_path_from(Rails.root).to_s
      next [] if EXEMPT.include?(rel)

      File.readlines(path).each_with_index.filter_map do |line, i|
        # `walletProvider.detect()` assigned into a variable is the shape that
        # precedes a dereference. Reading it inside a boolean guard
        # (`if (!walletProvider.detect())`) is not the bug and is not flagged.
        next unless line =~ DEREFERENCE_SHAPE
        "#{rel}:#{i + 1}"
      end
    end
  end

  test "no view assigns walletProvider.detect() into a variable it will dereference" do
    offenders = offending_lines

    assert_empty offenders,
                 "These views take a provider from detect(), which returns null on every " \
                 "mobile browser, and dereference it — the exact shape that printed " \
                 "\"null is not an object (evaluating 'provider.connect')\" into a " \
                 "transaction modal on 2026-09-07. Use walletProvider.requireProvider() " \
                 "instead; it throws a message the device can act on, and every one of " \
                 "these call sites already sits in a try/catch that renders err.message.\n  " +
                 offenders.join("\n  ")
  end

  # DERIVED FROM THE CALLERS, not from a hardcoded list. A stub owes whatever
  # the pre-hydration window can actually reach for, and that set grows: when
  # _alpine_factories moved from requireProvider to requireInlineProvider, a
  # list written by hand would have kept asserting the old name and passed while
  # the preview threw "requireInlineProvider is not a function". Reading the
  # call sites means adding a third guard updates this test for free.
  test "every layout inlining a walletProvider stub mirrors what its callers ask for" do
    factories = File.read(VIEWS.join("shared/_alpine_factories.html.erb"))
    needed = %w[requireProvider requireInlineProvider].select do |m|
      factories.include?("walletProvider.#{m}()")
    end
    assert_operator needed.size, :>=, 1,
                    "no walletProvider guard is called pre-hydration any more — if that is " \
                    "true then this test and the stubs it guards should go together"

    Dir.glob(Rails.root.join("app/views/layouts/*.erb")).each do |path|
      src = File.read(path)
      next unless src.include?("window.walletProvider = {")
      needed.each do |m|
        assert_includes src, "#{m}: function()",
                        "#{File.basename(path)} stubs walletProvider without #{m}, and " \
                        "shared/_alpine_factories calls it — the pre-hydration window there " \
                        "throws \"#{m} is not a function\"."
      end
    end
  end

  test "the guard is actually in use, so the scan above is not vacuous" do
    # A REGEX THAT MATCHES NOTHING PASSES THE TEST ABOVE FOREVER, and counting
    # requireProvider() callers does NOT close that — it never runs the pattern.
    # Mutation-verified 2026-09-08: /ZZZ_NEVER/ left both tests here green.
    [
      "          var provider = window.walletProvider.detect();",
      "      var provider = window.walletProvider && window.walletProvider.detect();"
    ].each do |bad|
      assert_match DEREFERENCE_SHAPE, bad,
                   "the scan's pattern no longer recognises the shape it exists to find, " \
                   "so the invariant above is being enforced over an empty set: #{bad.strip}"
    end
    # Must still IGNORE the boolean-guard read, or the scan flags correct code.
    refute_match DEREFERENCE_SHAPE, "      if (!window.walletProvider.detect()) return;"

    # THE GUARD IS NOW TWO FUNCTIONS, and both count. requireProvider() answers
    # with whatever wallet the device has, INCLUDING a redirect provider — which
    # is correct only for a caller that forks on provider.transport. Every other
    # caller wants requireInlineProvider(), which refuses a redirect provider
    # with the same device-appropriate message, because a redirect provider has
    # no connect/signTransaction/signMessage and reaching for them reproduces
    # the original incident one call site over.
    #
    # THE FLOOR MOVED FROM SIX TO FOUR, DELIBERATELY — which is what the old
    # message asked the next reader to do rather than delete the check.
    # /tasks/migrate-remaining-entry-flows routed the survivor board,
    # contests/new and contests/generator through shared/_wallet_op_runner
    # (window.tmWalletOp), and the runner acquires the provider ONCE for all
    # three. So three call sites did not lose their guard; they stopped each
    # holding a copy of it.
    #
    # THAT IS A DIFFERENT MOVE FROM THE ONE THIS COMMENT USED TO DESCRIBE, and
    # both happened. Converting a view to the stricter sibling does NOT move
    # this total — a site that LEARNS the redirect transport moves BETWEEN the
    # two guards, it does not stop calling one. Consolidating three call sites
    # onto one runner DOES move it, because three views genuinely stopped
    # asking. Only the second kind lowers this number, and it is the kind that
    # happened here.
    #
    # FLOOR LOWERED 4 → 3 ON PURPOSE, 2026-09-10, by the same move as above:
    # /tasks/route-board-through-runner routed the turf-totals board through
    # window.tmWalletOp, so the board stopped asking and the runner asks on its
    # behalf. MEASURED ON THIS TREE, three views ask directly: the runner, the
    # alpine factories and the wallet export.
    guards = %w[
      walletProvider.requireProvider()
      walletProvider.requireInlineProvider()
    ]
    users = Dir.glob(VIEWS.join("**/*.erb")).count do |p|
      src = File.read(p)
      guards.any? { |g| src.include?(g) }
    end

    assert_operator users, :>=, 3,
                    "expected at least the three signing views that still ask directly to call " \
                    "requireProvider() or requireInlineProvider(); found #{users}. If a " \
                    "call site was removed on purpose, lower this floor deliberately " \
                    "rather than deleting the check."

    # AND THE RUNNER MUST BE ONE OF THEM. This is what makes the lowered floor
    # honest rather than a weakening: the four flows that stopped asking did so
    # because ONE place now asks on their behalf. Delete the guard there and
    # four flows dereference whatever detect() returned — the original incident,
    # reproduced four times from a single edit.
    runner = VIEWS.join("shared/_wallet_op_runner.html.erb")
    assert File.exist?(runner), "the shared wallet-op runner is missing — four flows have no guard at all"
    assert_includes File.read(runner), "walletProvider.requireProvider()",
                    "tmWalletOp is where both contest boards, contest create and bundle " \
                    "provisioning get their provider; without the guard here all four " \
                    "dereference whatever detect() answered"

    # AND THE STRICTER ONE MUST ACTUALLY BE USED. Without this, converting every
    # remaining site back to the permissive guard would keep the count up and hand
    # a redirect provider to callers that cannot drive it — the defect this whole
    # change exists to close. TWO, not three: the survivor board was the third,
    # and it no longer needs the stricter sibling because it is now TAUGHT the
    # redirect transport rather than refusing it.
    inline = Dir.glob(VIEWS.join("**/*.erb")).count do |p|
      File.read(p).include?("walletProvider.requireInlineProvider()")
    end

    # FLOOR LOWERED 3 → 1 ON PURPOSE, 2026-09-09, in TWO independent steps that
    # merged together. This is the move this test's own comment asks for
    # instead of deleting a check, and it has now reached the number that
    # comment predicted it would stop at.
    #
    # STEP ONE, 3 → 2: shared/_alpine_factories GRADUATED. It held a slot
    # because tmUsernameFinalize hand-rolled the on-chain arc for an injected
    # wallet and could not drive a redirect provider — so refusing one was
    # correct. That rename now runs through SolanaStudio.walletOps.run (the
    # username_rename intent in shared/_username_rename_intent), which owns both
    # transports, so the file forks on provider.transport and requireProvider()
    # is the RIGHT guard there. It did not stop guarding; it moved to the other
    # guard, and the total floor above is what holds that.
    #
    # STEP TWO, 2 → 1: the SURVIVOR BOARD graduated the same way, for the same
    # reason, in /tasks/migrate-remaining-entry-flows. It is now taught the
    # redirect transport through window.tmWalletOp rather than refusing one, so
    # it too moved between the guards rather than dropping one.
    #
    # THE ONE THAT REMAINS IS NOT PENDING WORK OF THE SAME KIND, so this floor
    # is expected to STOP here rather than keep sliding. The wallet export is a
    # DELIBERATE PERMANENT no — it signs a MESSAGE, and walletOps has no
    # signMessage hop; more to the point the message carries the export token,
    # which is a bearer credential for the decrypted private key, and the
    # redirect transport would journal it to localStorage. Reasons in full at
    # /tasks/wallet-export-mobile-transport and in that view's own comment.
    # A future reader finding this at 0 should treat it as a REGRESSION and
    # look for a lost guard, not lower it again.
    assert_operator inline, :>=, 1,
                    "the wallet export is the one view that cannot drive a redirect " \
                    "provider — it signs a bearer-credential message — and it must ask " \
                    "for an INLINE provider; found #{inline}."
  end
end
