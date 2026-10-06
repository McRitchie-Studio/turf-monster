require "test_helper"
require "minitest/mock"

# [unit] The contest test-action buttons (jump, simulate, fill, reset) render
# only while ENABLE_TEST_SCAFFOLDING is on: on the contest page, in the
# leaderboard admin row, and on the admin hub. The batch and jump buttons ask
# for a confirm before they post.
class ContestTestActionButtonsTest < ActionDispatch::IntegrationTest
  setup do
    @contest = contests(:one)
    log_in_as(users(:alex)) # admin
  end

  def gated_paths
    [
      jump_contest_path(@contest),
      simulate_game_contest_path(@contest),
      simulate_batch_contest_path(@contest, count: 5),
      simulate_batch_contest_path(@contest, count: 20),
      fill_contest_path(@contest),
      reset_contest_path(@contest)
    ]
  end

  def assert_no_test_action_forms
    gated_paths.each do |path|
      assert_select "form[action=?]", path, count: 0, message: "#{path} must not render with the flag off"
    end
  end

  test "the contest page renders no test-action button with the flag off" do
    AppFlags.stub :test_scaffolding?, false do
      get contest_path(@contest)
    end

    assert_response :success
    assert_no_test_action_forms
  end

  test "the contest page renders the test-action buttons, batch and jump confirmed, with the flag on" do
    AppFlags.stub :test_scaffolding?, true do
      get contest_path(@contest)
    end

    assert_response :success
    assert_select "form[action=?]", jump_contest_path(@contest), minimum: 1
    assert_select "form[action=?]", fill_contest_path(@contest), minimum: 1
    css_select("form[action='#{jump_contest_path(@contest)}'], form[action^='#{simulate_batch_contest_path(@contest)}']").each do |form|
      assert form["data-turbo-confirm"].present? || form.at_css("[data-turbo-confirm]"),
        "#{form['action']} must ask for a confirm"
    end
  end

  test "the admin hub renders no Reset Contest with the flag off" do
    AppFlags.stub :test_scaffolding?, false do
      get admin_hub_path
    end

    assert_response :success
    assert_select "form[action$='/reset']", count: 0
  end

  test "the admin hub renders Reset Contest with the flag on" do
    AppFlags.stub :test_scaffolding?, true do
      get admin_hub_path
    end

    assert_response :success
    assert_select "form[action$='/reset']", count: 1
  end
end
