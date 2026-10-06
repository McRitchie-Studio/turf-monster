require "test_helper"

# [integration] The read-only admin list of slate-drop signups.
class Admin::DropSignupsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @old = DropSignup.create!(email: "old@example.com", slate_key: NextSlateDrop::SLATE_KEY, created_at: 2.days.ago)
    @new = DropSignup.create!(email: "new@example.com", slate_key: NextSlateDrop::SLATE_KEY, source: "tiktok")
    DropSignup.create!(email: "later@example.com", slate_key: "nfl-2026-weeks-10-12")
  end

  test "requires admin" do
    get admin_drop_signups_path
    assert_response :redirect

    log_in_as(users(:jordan))
    get admin_drop_signups_path
    assert_response :redirect
  end

  test "lists the next drop's signups newest first, with a count" do
    log_in_as(users(:alex))
    get admin_drop_signups_path
    assert_response :success
    assert_select '[data-test="drop-signups-total"]', text: "2"
    body = response.body
    assert_operator body.index("new@example.com"), :<, body.index("old@example.com")
    refute_includes body, "later@example.com", "another drop's list stays on its own pill"
  end

  test "switches drops by slate" do
    log_in_as(users(:alex))
    get admin_drop_signups_path(slate: "nfl-2026-weeks-10-12")
    assert_includes response.body, "later@example.com"
    refute_includes response.body, "old@example.com"
  end

  test "exports the drop's list as CSV" do
    log_in_as(users(:alex))
    get admin_drop_signups_path(format: :csv)
    assert_response :success
    assert_equal "text/csv", response.media_type
    rows = CSV.parse(response.body, headers: true)
    assert_equal %w[new@example.com old@example.com], rows.map { |r| r["email"] }
    assert_equal "tiktok", rows.first["source"]
  end

  test "the CSV quotes cells a spreadsheet would run as formulas" do
    DropSignup.create!(email: "=1+1@example.com", slate_key: NextSlateDrop::SLATE_KEY, source: '=HYPERLINK("http://x")')
    log_in_as(users(:alex))
    get admin_drop_signups_path(format: :csv)
    row = CSV.parse(response.body, headers: true).find { |r| r["email"].include?("1+1") }
    assert_equal ["'=1+1@example.com", %('=HYPERLINK("http://x"))], [row["email"], row["source"]]
  end

  test "the admin hub links the list" do
    log_in_as(users(:alex))
    get admin_hub_path
    assert_select %(a[href="#{admin_drop_signups_path}"])
  end
end
