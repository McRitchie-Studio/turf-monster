require "test_helper"

# [integration] turf-frozen-account-followups, as rendered pages: the landing
# layout lifts the banner above the funnel backgrounds, and the contest page
# hands its pick board and chat what they need to answer a frozen account's tap
# with the freeze rather than "Entry Failed" or "Join to react". Each case has a
# control for the account in good standing.
class FrozenAccountFollowupsPagesTest < ActionDispatch::IntegrationTest
  setup do
    @user    = users(:jordan) # an entrant in contest :one
    @contest = contests(:one)
    log_in_as(@user)
  end

  def board_config
    JSON.parse(css_select("script#board-config").first.text)
  end

  def chat_root
    css_select("[data-can-react]").first
  end

  test "a landing page puts the frozen banner in a positioned layer above its z-0 background" do
    @user.freeze!(reason: "test", source: "console")
    get landing_page_path(landing_pages(:launch).slug)

    assert_response :success
    layer = css_select("[data-frozen-banner-layer]")
    assert_equal 1, layer.size
    assert_equal %w[relative z-20], layer.first["class"].split,
                 "fixed backgrounds sit at z-0 and the splash at z-10; the banner must outrank both"
    assert_equal 1, layer.first.css("[data-frozen-banner]").size
    assert_select "[data-frozen-banner]", 1
  end

  test "control: a landing page shows an account in good standing no banner layer" do
    get landing_page_path(landing_pages(:launch).slug)

    assert_select "[data-frozen-banner-layer]", 0
    assert_select "[data-frozen-banner]", 0
  end

  # Jordan's entry hides the pick board, so the board is read as Casey, who has
  # not entered contest :one; the chat is read as Jordan, who has.
  test "the pick board carries the freeze for a frozen account" do
    casey = users(:casey)
    log_in_as(casey)
    casey.freeze!(reason: "test", source: "console")
    get contest_path(@contest)

    assert_equal({ "title" => FrozenAccount::TOAST_TITLE, "message" => FrozenAccount::MESSAGE,
                   "code" => FrozenAccount::CODE }, board_config["frozen"])
    assert_includes response.body, "if (this.frozen) { this.showError(this.frozen.message, this.frozen.code); return; }"
  end

  test "control: the pick board carries no freeze for an account in good standing" do
    log_in_as(users(:casey))
    get contest_path(@contest)

    assert_nil board_config["frozen"]
  end

  test "the chat answers a frozen entrant's reaction with the freeze" do
    @user.freeze!(reason: "test", source: "console")
    get contest_path(@contest)

    assert chat_root.key?("data-account-frozen")
    assert_includes response.body, "chatToast(#{FrozenAccount::TOAST_TITLE.to_json}, #{FrozenAccount::MESSAGE.to_json})"
  end

  test "control: an entrant in good standing's chat carries no freeze" do
    get contest_path(@contest)

    assert_not chat_root.key?("data-account-frozen")
    assert_equal "true", chat_root["data-can-react"]
  end

  # The freeze copy reaches the inline JS as JSON literals, so an apostrophe or
  # quote in it can never arrive HTML-escaped (&#39;) inside a toast.
  test "the freeze copy is written into the board and chat scripts as JSON, never HTML-escaped" do
    with_copy = "Your account's frozen. Contact \"support\"."
    original = FrozenAccount::MESSAGE
    FrozenAccount.send(:remove_const, :MESSAGE)
    FrozenAccount.const_set(:MESSAGE, with_copy)
    begin
      @user.freeze!(reason: "test", source: "console")
      get contest_path(@contest)
    ensure
      FrozenAccount.send(:remove_const, :MESSAGE)
      FrozenAccount.const_set(:MESSAGE, original)
    end

    assert_includes response.body, "chatToast(#{FrozenAccount::TOAST_TITLE.to_json}, #{with_copy.to_json})"
    assert_includes response.body, "code === #{FrozenAccount::CODE.to_json} ?"
    assert_not_includes response.body, "Your account&#39;s frozen"
  end
end
