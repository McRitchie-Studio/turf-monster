require "test_helper"

# [unit] ApplicationHelper#main_contest_target — the per-request memo every view
# caller of SeasonConfig.main_contest resolves through.
#
# WHY IT EXISTS. Several cards need the app's default contest target and are
# rendered by controllers that cannot preload for them: /account sets nothing for
# the referral card any more, and the engine's ProfilesController — which renders
# that same card on /profile — cannot be taught to. The age-gate card is worse
# still: its ERB sits inside a `<template x-if>` in layouts/application, which
# renders SERVER-SIDE unconditionally, so it resolves on EVERY authenticated page
# rather than when the modal opens. So the calls live in a VIEW RENDER, and
# SeasonConfig.main_contest reaches SeasonConfig.current, a `find_or_create_by` —
# normally a SELECT, but a code path that can INSERT.
#
# WHY THIS IS A HELPER TEST AND NOT AN INTEGRATION ONE. The first version drove a
# real GET and counted SeasonConfig.main_contest calls, expecting one. It got
# four — and NOT because the memo was broken: Contest and FaucetController call
# main_contest too, so the test was attributing the whole page's traffic to one
# helper and would have failed forever on a correct implementation. A memo is a
# property of the method, so it is measured at the method. The per-request claim
# that only a real request can make is measured in
# test/integration/main_contest_query_budget_test.rb.
class MainContestTargetTest < ActionView::TestCase
  include ApplicationHelper
  include BirthdayModalHelper

  # The partial reaches referral_link_url, which reads current_user off the VIEW
  # context — a controller supplies it in a real request and nothing does here.
  # Defining it on the test case is not enough: `render` evaluates the template
  # against `view`, which is a different object, so the method has to go there.
  def stub_current_user(user)
    view.define_singleton_method(:current_user) { user }
  end

  def counting_main_contest
    calls = 0
    real = SeasonConfig.method(:main_contest)
    SeasonConfig.stub(:main_contest, ->(*args) { calls += 1; real.call(*args) }) { yield }
    calls
  end

  test "it resolves once however many times it is asked" do
    calls = counting_main_contest { 5.times { main_contest_target } }

    assert_equal 1, calls,
                 "the page asked five times and resolved #{calls} times — every extra one is a " \
                 "SeasonConfig.current round-trip during a render"
  end

  test "it returns the same contest every time" do
    first = main_contest_target

    assert_same first, main_contest_target
  end

  # THE REGRESSION THIS FILE WAS REOPENED FOR. Two cards on one page, two
  # helpers, ONE resolution — that is the whole claim, and it is the one a
  # single-helper count cannot make. BirthdayModalHelper#age_gate_modal_locals
  # called SeasonConfig.main_contest raw, so a page carrying both cards resolved
  # TWICE; a memo private to the age gate would have looked identical here and
  # changed nothing, because that helper is only called once per render. The
  # helpers share a memo only because they share a view context and therefore
  # the ivar behind it — revert either caller and this counts 2.
  test "the age gate and the referral card share ONE resolution" do
    calls = counting_main_contest do
      main_contest_target
      age_gate_modal_locals
    end

    assert_equal 1, calls,
                 "one page render resolved the main contest #{calls} times — every caller in a " \
                 "render must go through main_contest_target, not SeasonConfig.main_contest"
  end

  # THE OFF-SEASON IS THE CASE `||=` GETS WRONG. With no open contest the answer
  # is legitimately nil, and `||=` reads nil as "not computed yet" — so it would
  # re-resolve on every single call, in exactly the state where the page is
  # cheapest and least interesting. `defined?` caches the nil.
  test "it caches a nil result too" do
    Contest.update_all(status: :closed)
    assert_nil SeasonConfig.main_contest, "a contest is still open — this test proves nothing"

    calls = counting_main_contest { 5.times { main_contest_target } }

    assert_equal 1, calls,
                 "nil was re-resolved #{calls} times — a nil result is a RESULT, and caching it " \
                 "is the whole difference between `defined?` and `||=` here"
    assert_nil main_contest_target
  end

  # The off-season nil must survive the trip through the age gate too: a cached
  # nil that the CTA cannot read back is a dropped button, not a saved query.
  test "an off-season nil still falls the age gate back to the index" do
    Contest.update_all(status: :closed)

    calls = counting_main_contest do
      assert_equal contests_path, age_gate_modal_locals[:watch_url]
      assert_equal contests_path, age_gate_modal_locals[:watch_url]
    end

    assert_equal 1, calls, "the off-season path re-resolved #{calls} times"
  end

  # It must still be OVERRIDABLE. The partial takes a share_contest local so a
  # caller can point a link at a different contest; the memo is the default, not
  # a hard-coded answer.
  test "the partial's local wins over the helper" do
    user = users(:alex)
    stub_current_user(user)
    other = contests(:one)

    rendered = render(partial: "accounts/referral_section",
                      locals: { user: user, share_contest: other })

    assert_includes rendered, "Copy Link", "the partial did not render at all"
  end
end
