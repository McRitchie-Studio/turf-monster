require "test_helper"

class Admin::DashboardControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin   = users(:alex)
    @user    = users(:jordan)
    @contest = contests(:one)
  end

  test "show requires admin" do
    log_in_as(@user)
    get admin_dashboard_path
    assert_response :redirect
  end

  test "show requires login" do
    get admin_dashboard_path
    assert_response :redirect
  end

  test "show renders for admin" do
    log_in_as(@admin)
    get admin_dashboard_path
    assert_response :success
    assert_select "h1", text: "Dashboard"
    assert_select "a[href=?]", admin_models_path
    assert_select "form"
  end

  test "show links the NFL points distribution report" do
    log_in_as(@admin)
    get admin_dashboard_path
    assert_response :success
    assert_select "a[href=?]", nfl_report_slates_path, text: /🏈 NFL Points Distribution/
  end

  # The live board and the page that orders it, as a PAIR — the only way to see
  # what a focus order does is to open the board it drives, so a dashboard that
  # offers one without the other sends the operator hunting for the other half.
  test "show links the live board and the week that orders it" do
    log_in_as(@admin)
    get admin_dashboard_path

    assert_response :success
    assert_select "a[href=?]", live_path, text: /Live Board/
    assert_select "a[href=?]", admin_nfl_weeks_path, text: /Focus Order/
  end

  test "show surfaces a settled explicit pick alongside its resolved fallback" do
    settled = Contest.create!(
      name: "Settled Pick", status: :settled, contest_type: "small",
      entry_fee_cents: 1900, max_entries: 5, slate: slates(:one),
      starts_at: 1.week.from_now, rank: 100
    )
    SeasonConfig.set_main_contest!(settled)

    log_in_as(@admin)
    get admin_dashboard_path
    assert_response :success
    # The "Admin-set" line shows the settled pick even though main_contest
    # masks it; the page lets the admin see the mismatch.
    assert_select "div", text: /Settled Pick/
  end

  test "update sets main_contest" do
    log_in_as(@admin)
    assert_nil SeasonConfig.main_contest_explicit

    patch admin_dashboard_path, params: { main_contest_id: @contest.id }

    assert_redirected_to admin_dashboard_path
    assert_equal @contest, SeasonConfig.main_contest_explicit
  end

  test "update with empty value clears main_contest" do
    SeasonConfig.set_main_contest!(@contest)
    assert_equal @contest, SeasonConfig.main_contest_explicit

    log_in_as(@admin)
    patch admin_dashboard_path, params: { main_contest_id: "" }

    assert_redirected_to admin_dashboard_path
    assert_nil SeasonConfig.main_contest_explicit
  end

  test "update rejects non-admin" do
    log_in_as(@user)
    patch admin_dashboard_path, params: { main_contest_id: @contest.id }
    assert_response :redirect
    assert_nil SeasonConfig.main_contest_explicit
  end

  # --- Link-preview (og:image) defaults ---

  test "show renders the link-preview defaults section" do
    log_in_as(@admin)
    get admin_dashboard_path
    assert_response :success
    assert_select "h2", text: "Link Preview Defaults"
    assert_select "#default-og-image-preview"
  end

  test "update_link_preview saves the default title and description" do
    log_in_as(@admin)
    patch admin_dashboard_link_preview_path, params: {
      site_setting: { default_og_title: "Custom Title", default_og_description: "Custom Desc" }
    }
    assert_redirected_to admin_dashboard_path
    assert_equal "Custom Title", SiteSetting.instance.default_og_title
    assert_equal "Custom Desc",  SiteSetting.instance.default_og_description
  end

  test "update_link_preview rejects non-admin" do
    log_in_as(@user)
    patch admin_dashboard_link_preview_path, params: {
      site_setting: { default_og_title: "Nope" }
    }
    assert_response :redirect
    assert_nil SiteSetting.instance.default_og_title
  end

  test "update_link_preview_image attaches the default og image" do
    log_in_as(@admin)
    assert_not SiteSetting.instance.default_og_image.attached?

    patch admin_dashboard_link_preview_image_path,
      params: { site_setting: { default_og_image: fixture_file_upload("banner.png", "image/png") } },
      as: :turbo_stream

    assert_response :success
    assert SiteSetting.instance.reload.default_og_image.attached?
    assert_match "default-og-image-preview", response.body
  end

  test "update_link_preview_image rejects a non-image file" do
    log_in_as(@admin)
    patch admin_dashboard_link_preview_image_path,
      params: { site_setting: { default_og_image: fixture_file_upload("not_an_image.txt", "text/plain") } }
    assert_response :redirect
    assert_not SiteSetting.instance.reload.default_og_image.attached?
  end

  test "update_link_preview_image rejects non-admin" do
    log_in_as(@user)
    patch admin_dashboard_link_preview_image_path,
      params: { site_setting: { default_og_image: fixture_file_upload("banner.png", "image/png") } }
    assert_response :redirect
    assert_not SiteSetting.instance.reload.default_og_image.attached?
  end
end
