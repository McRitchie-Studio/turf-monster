require "test_helper"

# [integration] What a frozen account SEES (OPSEC-048): the banner on every
# page, and the calls to action it cannot use shown disabled with the reason.
# The control is the same pages for the account in good standing: no banner,
# live buttons.
class FrozenAccountBannerTest < ActionDispatch::IntegrationTest
  setup do
    @user    = users(:jordan) # an entrant in contest :one, so its chat is open to them
    @contest = contests(:one)
    log_in_as(@user)
  end

  def pages
    [contests_path, contest_path(@contest), my_contests_path, account_path, wallet_path]
  end

  test "every page shows a frozen account the banner, once" do
    @user.freeze!(reason: "test", source: "console")

    pages.each do |path|
      get path
      assert_response :success, path
      assert_select "[data-frozen-banner]", { count: 1 }, "#{path}: the banner is missing or doubled"
      assert_select "[data-frozen-banner]", text: /Your account is frozen/
    end
  end

  test "control: an account in good standing sees no banner" do
    pages.each do |path|
      get path
      assert_select "[data-frozen-banner]", { count: 0 }, path
    end
  end

  test "the contest page swaps the chat composer and the entry button for the reason" do
    @user.freeze!(reason: "test", source: "console")
    get contest_path(@contest)

    assert_select "#contest-chat-input", 0
    assert_select "[data-frozen-cta]", text: "Chat is off while your account is frozen."
  end

  test "control: the entrant's contest page has its chat composer" do
    get contest_path(@contest)
    assert_select "#contest-chat-input", 1
    assert_select "[data-frozen-cta]", 0
  end

  test "the account page disables Change username and says why" do
    @user.freeze!(reason: "test", source: "console")
    get account_path

    assert_select "button[disabled][data-frozen-cta][title=?]", FrozenAccount::CTA_REASON, text: /Username locked/
  end
end
