require "test_helper"

# [unit] ApplicationHelper#referral_share_contest — the per-request memo.
#
# WHY IT EXISTS. The referral card is rendered by two pages, and only one has a
# controller that can preload for it: /account set @referral_share_contest, and
# the engine's ProfilesController — which renders the same card on /profile —
# cannot be made to. So the card resolves its own default, which moved the call
# out of a controller and into a VIEW RENDER. SeasonConfig.main_contest reaches
# SeasonConfig.current, a `find_or_create_by`; this keeps it to one resolution
# however many times the card asks.
#
# WHY THIS IS A HELPER TEST AND NOT AN INTEGRATION ONE. The first version drove a
# real GET and counted SeasonConfig.main_contest calls, expecting one. It got
# four — and NOT because the memo was broken: Contest and FaucetController call
# main_contest too, so the test was attributing the whole page's traffic to one
# helper and would have failed forever on a correct implementation. A memo is a
# property of the method, so it is measured at the method.
class ReferralShareContestTest < ActionView::TestCase
  include ApplicationHelper

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
    calls = counting_main_contest { 5.times { referral_share_contest } }

    assert_equal 1, calls,
                 "the card asked five times and resolved #{calls} times — every extra one is a " \
                 "SeasonConfig.current round-trip during a render"
  end

  test "it returns the same contest every time" do
    first = referral_share_contest

    assert_same first, referral_share_contest
  end

  # THE OFF-SEASON IS THE CASE `||=` GETS WRONG. With no open contest the answer
  # is legitimately nil, and `||=` reads nil as "not computed yet" — so it would
  # re-resolve on every single call, in exactly the state where the page is
  # cheapest and least interesting. `defined?` caches the nil.
  test "it caches a nil result too" do
    Contest.update_all(status: :closed)
    assert_nil SeasonConfig.main_contest, "a contest is still open — this test proves nothing"

    calls = counting_main_contest { 5.times { referral_share_contest } }

    assert_equal 1, calls,
                 "nil was re-resolved #{calls} times — a nil result is a RESULT, and caching it " \
                 "is the whole difference between `defined?` and `||=` here"
    assert_nil referral_share_contest
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
