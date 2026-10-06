require "test_helper"

# [component] turf-frozen-account-followups, read from the partials alone: the
# banner's phone-width form and the withdraw card's inline reason. Each has a
# control for the account in good standing.
class FrozenAccountFollowupsViewTest < ActionView::TestCase
  include FrozenAccountHelper

  attr_accessor :viewer

  def current_user = viewer
  def logged_in? = viewer.present?

  setup do
    self.viewer = users(:jordan)
    test = self
    view.singleton_class.define_method(:current_user) { test.viewer }
    view.singleton_class.define_method(:logged_in?) { test.viewer.present? }
  end

  def fragment(html) = Nokogiri::HTML5.fragment(html)

  test "below sm the banner carries the headline and the contact, and hides only the detail" do
    banner = fragment(render(partial: "shared/frozen_account_banner")).at_css("[data-frozen-banner]")

    detail = banner.at_css("[data-frozen-banner-detail]")
    assert_equal %w[hidden sm:inline], detail["class"].split, "the detail shows from sm up only"
    assert_equal " #{FrozenAccount::BANNER_DETAIL}", detail.text

    phone_text = banner.dup.tap { |b| b.at_css("[data-frozen-banner-detail]").remove }.text
    assert_includes phone_text, FrozenAccount::BANNER_HEADLINE
    assert_includes phone_text, "support@turfmonster.media"
    assert_includes banner.text, FrozenAccount::BANNER, "from sm up the full sentence reads as one"
  end

  test "a frozen viewer's withdraw card says why in the card, not only on hover" do
    viewer.freeze!(reason: "test", source: "console")
    doc = fragment(render(partial: "wallets/withdraw_card"))

    reason = doc.at_css("[data-frozen-reason]")
    assert reason, "the reason is printed inline"
    assert_includes reason.text, "withdrawals are off"
    assert_equal "cash-out-frozen-reason", reason["id"]
    assert_equal reason["id"], doc.at_css("button[data-frozen-cta]")["aria-describedby"]
    assert_match(/open: false/, doc.at_css("#cash-out")["x-data"], "a #cash-out link cannot open the form")
  end

  test "control: a viewer in good standing sees no inline reason and the hash still opens the form" do
    doc = fragment(render(partial: "wallets/withdraw_card"))

    assert_nil doc.at_css("[data-frozen-reason]")
    assert_match(/open: window\.location\.hash === '#cash-out'/, doc.at_css("#cash-out")["x-data"])
  end
end
