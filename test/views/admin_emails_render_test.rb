require "test_helper"

# [component] The shared engine emails page, as turf-monster renders it.
#
# The engine owns this view, so this does not re-test the engine's own suite.
# What it pins is the SEAM: that turf-monster's registry data reaches the page,
# and that the page it reaches is the ENGINE's — the app deleted its own
# Admin::EmailsController and the three routes that owned the admin_emails /
# admin_email helper names, and a stray local route would silently take them back.
class AdminEmailsRenderTest < ActionDispatch::IntegrationTest
  setup { log_in_as(users(:alex)) }

  test "the page is the engine's, not a local one" do
    route = Rails.application.routes.routes.find { |r| r.name == "admin_emails" }
    assert_equal "studio/emails", route.defaults[:controller]

    refute Object.const_defined?("Admin::EmailsController"),
      "the local email manager was retired — two pages is what this change removes"
  end

  test "the table renders one row per registered email, name and image together" do
    get admin_emails_path
    assert_response :success

    assert_select "tbody tr", count: Studio::EmailCatalog.entries.size
    Studio::EmailCatalog.entries.each do |entry|
      assert_select "tbody", text: /#{Regexp.escape(entry.label)}/,
        message: "#{entry.key} should be identifiable by name"
    end
    assert_select "tbody img", count: Studio::EmailCatalog.entries.size,
      message: "every row shows its live banner, not just its name"
  end

  test "each row links to that email's own preview page" do
    get admin_emails_path

    Studio::EmailCatalog.keys.each do |key|
      assert_select "a[href=?]", admin_email_path(key)
    end
  end

  test "the marketing email is badged and the transactional ones are not" do
    get admin_emails_path

    assert_select "tbody", text: /Marketing/, count: 1
  end

  test "an email's page renders its banner and its preview frame" do
    get admin_email_path("contest_winnings")
    assert_response :success

    assert_select "img[src*=?]", "winnings-banner"
    assert_select "iframe[src=?]", admin_email_raw_path("contest_winnings")
  end
end
