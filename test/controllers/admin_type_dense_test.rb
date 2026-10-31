# frozen_string_literal: true

require "test_helper"

# [component] Task turf-adopts-type-scale: an admin-only page reads the type
# scale's 14px dense base, through `type-dense` on <body> (on <html> the theme
# tag's unlayered :root rule would win). Admin-only means `require_admin` ran
# for the page (ApplicationController#type_dense_page?), so the same admin on a
# player page, and a player on their own account page, keep the 16px base. The
# theme tag carries the turf brand kit's four settings either way.
class AdminTypeDenseTest < ActionDispatch::IntegrationTest
  def body_classes = css_select("body").first["class"].split

  test "an Admin:: page puts type-dense on body, not html" do
    log_in_as(users(:alex))
    get admin_dashboard_path
    assert_response :success
    assert_includes body_classes, "type-dense"
    refute_includes css_select("html").first["class"].to_s.split, "type-dense"
  end

  test "an admin-guarded action outside the Admin:: namespace is dense too" do
    log_in_as(users(:alex))
    get admin_transactions_path
    assert_response :success
    assert_includes body_classes, "type-dense"
  end

  test "the same admin on a player page keeps the 16px base" do
    log_in_as(users(:alex))
    get contests_path
    assert_response :success
    refute_includes body_classes, "type-dense"
  end

  test "a visitor's page keeps the 16px base" do
    get contests_path
    assert_response :success
    refute_includes body_classes, "type-dense"
  end

  test "a signed-in player's own page keeps the 16px base" do
    log_in_as(users(:jordan))
    get account_path
    assert_response :success
    refute_includes body_classes, "type-dense"
  end

  test "the theme tag carries the turf brand kit's type scale" do
    get contests_path
    assert_includes response.body, "--type-base: 16px;"
    assert_includes response.body, "--type-dense-base: 14px;"
    assert_includes response.body, "--type-display-weight: 800;"
    assert_includes response.body, "--type-text-weight: 500;"
  end
end
