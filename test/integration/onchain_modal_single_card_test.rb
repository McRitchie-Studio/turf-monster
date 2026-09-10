# frozen_string_literal: true

require "test_helper"

# [component] The single-card guard on the on-chain modal proxy, in the layout
# script a page ACTUALLY SHIPS (task: level-up-reveals-stale-modal).
#
# WHAT THIS TEST IS, AND WHAT IT IS NOT. It reads rendered source, so it proves
# the guard shipped to the page — it cannot prove the guard WORKS. Negate a
# condition inside one of these functions and every assertion below still passes.
# The behaviour is owned by e2e/level_up_stacked_modal.spec.js, which drives the
# real entry flow in a browser and asserts the modal STACK; this file is the
# cheap structural half that goes red when the guard is deleted outright or the
# proxy grows a second, unguarded way to push an on-chain card.
#
# THE DEFECT IT REMEMBERS. Alpine.store('solanaModal').show() is how this app
# spells a STEP TRANSITION inside one on-chain flow — a single contest entry
# calls it three times (Preparing Transaction, Sign Transaction, Confirming
# Onchain), contest create six, lock_contest.js six. It used to call
# $store.modals.open() every time, and open() PUSHES, so each flow left a tower
# of onchain-tx cards. Every write the proxy makes resolves through current(),
# so success() advanced only the last one and the cards underneath kept
# state 'processing' with dismissible:false for the life of the page. They were
# invisible (the host renders only current()) until something landed on top and
# was dismissed — which is how closing the level-up celebration came to reveal
# "Approve your free entry in your wallet..." for a settled transaction.
class OnchainModalSingleCardTest < ActionDispatch::IntegrationTest
  setup do
    @contest = contests(:one)
    get contest_path(@contest)
    follow_redirect! while response.redirect?
    assert_response :success
    @body = response.body
    # THE INPUT REACHED THE ASSERTIONS. A scan of a body that never carried the
    # layout script would pass every refute below and prove nothing, so pin a
    # sentinel from the block under test before reading anything out of it.
    # `assert` on an .include? rather than assert_includes THROUGHOUT this file:
    # the haystack is a whole rendered page, and assert_includes prints it. One
    # failure used to bury its own message under 780KB of markup.
    assert @body.include?("Alpine.store('solanaModal'"),
           "the layout's on-chain modal proxy is not on this page — every " \
           "assertion in this file would be vacuous"
  end

  test "show() resolves a live on-chain card before it pushes a new one" do
    guard = @body.index("var live = _liveTx();")
    push  = @body.index("Alpine.store('modals').open('onchain-tx', props);")

    assert guard, "show() no longer resolves the live onchain-tx entry — the flow's " \
                  "second and third steps will push duplicate cards again"
    assert push, "show() no longer opens an onchain-tx card at all"
    assert guard < push,
           "show() pushes before it checks for a live card, so the guard cannot stop a duplicate"
  end

  test "the proxy pushes an on-chain card from exactly one place" do
    # resolveEntry has its own open() and is deliberately not counted here: it
    # reads `modals.open(` off a local, and it already branches on what is
    # current before it pushes. This counts the ONE call spelled through the
    # store, which is show()'s.
    pushes = @body.scan("Alpine.store('modals').open('onchain-tx'").length
    assert_equal 1, pushes,
                 "expected exactly one Alpine.store('modals').open('onchain-tx') site (show()'s, " \
                 "behind the live-card guard); found #{pushes}. A second unguarded pusher rebuilds " \
                 "the stacked-card defect this guard exists to prevent"
  end

  test "the level-up celebration still refuses to clobber a non-dismissible card" do
    # The other half of the property, and the reason the obvious fix is wrong.
    # The celebration swaps over a dismissible card and opens ON TOP of one that
    # forbids dismissal, so a prompt the user still has to act on is never taken
    # off the screen. Deleting this condition trades one bug for a worse one.
    assert @body.include?("!(cur.props && cur.props.dismissible === false)"),
           "the level-up handler no longer tests dismissibility before swapping — " \
           "it will clobber a card that is guarding a pending signature"
    assert @body.include?("m.open('free-entry-earned', props);"),
           "the open-on-top branch is gone; the celebration can only swap now"
  end
end
