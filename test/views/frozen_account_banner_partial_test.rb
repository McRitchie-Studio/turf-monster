require "test_helper"

# [component] The frozen-account banner partial and the withdraw card's frozen
# state (OPSEC-048): what each renders, read from the partial alone.
class FrozenAccountBannerPartialTest < ActionView::TestCase
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

  test "the banner says the account is frozen, what still works, and who to contact, in full" do
    doc = fragment(render(partial: "shared/frozen_account_banner"))

    banner = doc.at_css("[data-frozen-banner]")
    assert banner
    assert_includes banner.text, FrozenAccount::BANNER
    assert_equal "mailto:support@turfmonster.media", banner.at_css("a")["href"]
    assert_nil doc.at_css(".truncate"), "the banner wraps; a truncated sentence would lose its contact"
  end

  test "account_frozen? reads the viewer's freeze, and is false signed out" do
    assert_not account_frozen?
    viewer.freeze!(reason: "test", source: "console")
    assert account_frozen?
    self.viewer = nil
    assert_not account_frozen?
  end

  test "a frozen viewer's Withdraw is a disabled button with the reason" do
    viewer.freeze!(reason: "test", source: "console")
    doc = fragment(render(partial: "wallets/withdraw_card"))

    button = doc.at_css("button[data-frozen-cta]")
    assert button
    assert button.key?("disabled")
    assert_equal FrozenAccount::CTA_REASON, button["title"]
  end

  test "control: a viewer in good standing gets the live Withdraw toggle" do
    doc = fragment(render(partial: "wallets/withdraw_card"))

    assert_nil doc.at_css("[data-frozen-cta]")
    assert doc.at_css("button[x-text]"), "the Withdraw / Cancel toggle"
  end
end
