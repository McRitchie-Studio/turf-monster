require "test_helper"

class Admin::LandingPagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin        = users(:alex)
    @user         = users(:jordan)
    @landing_page = landing_pages(:launch)
  end

  test "index requires admin" do
    log_in_as(@user)
    get admin_landing_pages_path
    assert_response :redirect
  end

  test "index lists landing pages for admins" do
    log_in_as(@admin)
    get admin_landing_pages_path
    assert_response :success
    assert_select "td", text: @landing_page.name
  end

  test "new renders the form" do
    log_in_as(@admin)
    get new_admin_landing_page_path
    assert_response :success
  end

  test "create makes a landing page" do
    log_in_as(@admin)
    assert_difference "LandingPage.count", 1 do
      post admin_landing_pages_path, params: {
        landing_page: { name: "May Promo", headline: "Play now", contest_id: contests(:one).id, active: true }
      }
    end
    assert_redirected_to admin_landing_pages_path
    lp = LandingPage.find_by(name: "May Promo")
    assert lp.active?
    assert_equal contests(:one).id, lp.contest_id
  end

  test "create rejects an active page with no contest" do
    log_in_as(@admin)
    assert_no_difference "LandingPage.count" do
      post admin_landing_pages_path, params: { landing_page: { name: "Bad", active: true } }
    end
    assert_response :unprocessable_entity
  end

  test "update changes a landing page" do
    log_in_as(@admin)
    patch admin_landing_page_path(@landing_page), params: { landing_page: { headline: "New Headline" } }
    assert_redirected_to admin_landing_pages_path
    assert_equal "New Headline", @landing_page.reload.headline
  end

  test "update renames a changed slug through rename_slug!" do
    log_in_as(@admin)
    renames = []
    original = LandingPage.instance_method(:rename_slug!)
    LandingPage.define_method(:rename_slug!) { |slug| renames << slug; original.bind_call(self, slug) }

    patch admin_landing_page_path(@landing_page), params: { landing_page: { slug: "launch-renamed", headline: "Renamed" } }

    assert_redirected_to admin_landing_pages_path
    assert_equal ["launch-renamed"], renames
    @landing_page.reload
    assert_equal "launch-renamed", @landing_page.slug
    assert_equal "Renamed", @landing_page.headline
  ensure
    LandingPage.remove_method(:rename_slug!)
  end

  test "update with a blank slug re-derives it from the name" do
    log_in_as(@admin)
    patch admin_landing_page_path(@landing_page), params: { landing_page: { name: "Fresh Name", slug: "" } }

    assert_redirected_to admin_landing_pages_path
    assert_equal "fresh-name", @landing_page.reload.slug
  end

  test "update refuses a taken or badly formed slug with the reason and writes nothing" do
    log_in_as(@admin)
    taken = LandingPage.create!(name: "Taken Page")
    old_slug = @landing_page.slug

    { taken.slug => "Slug has already been taken", "Not A Slug" => "Slug is invalid" }.each do |slug, reason|
      patch admin_landing_page_path(@landing_page), params: { landing_page: { slug: slug, headline: "Unsaved" } }

      assert_response :unprocessable_entity
      assert_select "li", text: reason
      @landing_page.reload
      assert_equal old_slug, @landing_page.slug
      assert_not_equal "Unsaved", @landing_page.headline
    end
  end


    log_in_as(@admin)
    assert_difference "LandingPage.count", -1 do
      delete admin_landing_page_path(@landing_page)
    end
    assert_redirected_to admin_landing_pages_path
  end

  test "navbar exposes the landing pages manager to admins" do
    log_in_as(@admin)
    get faucet_path
    assert_response :success
    assert_select "a[href=?]", admin_landing_pages_path # admin shortlist → manager
  end

  test "the contest dropdown includes retired-format contests" do
    write_retired_format!(Contest.create!(name: "Dropdown Survivor", slate: slates(:one), status: "open"))
    log_in_as(@admin)
    get new_admin_landing_page_path
    assert_response :success
    assert_select "select#landing_page_contest_id option", text: /Dropdown Survivor/
  end

  test "the form offers a background style choice" do
    log_in_as(@admin)
    get new_admin_landing_page_path
    assert_response :success
    assert_select "select#landing_page_background_style option", text: "Rotating blobs"
  end

  test "create accepts a background style" do
    log_in_as(@admin)
    post admin_landing_pages_path, params: {
      landing_page: { name: "Blobby Funnel", contest_id: contests(:one).id, active: true, background_style: "blobs" }
    }
    assert_redirected_to admin_landing_pages_path
    assert_equal "blobs", LandingPage.find_by(name: "Blobby Funnel").background_style
  end

  test "create accepts a badge label" do
    log_in_as(@admin)
    post admin_landing_pages_path, params: {
      landing_page: { name: "Badged Funnel", contest_id: contests(:one).id, badge: "Beta" }
    }
    assert_redirected_to admin_landing_pages_path
    assert_equal "Beta", LandingPage.find_by(name: "Badged Funnel").badge
  end

  # --- Per-page og:image upload ---

  test "edit shows the link-preview image uploader for a persisted page" do
    log_in_as(@admin)
    get edit_admin_landing_page_path(@landing_page)
    assert_response :success
    assert_select "#landing-og-image-preview"
    assert_select "#landing-og-image-form"
  end

  test "update_og_image attaches the per-page image" do
    log_in_as(@admin)
    assert_not @landing_page.og_image.attached?

    patch og_image_admin_landing_page_path(@landing_page),
      params: { landing_page: { og_image: fixture_file_upload("banner.png", "image/png") } },
      as: :turbo_stream

    assert_response :success
    assert @landing_page.reload.og_image.attached?
    assert_match "landing-og-image-preview", response.body
  end

  test "update_og_image rejects a non-image file" do
    log_in_as(@admin)
    patch og_image_admin_landing_page_path(@landing_page),
      params: { landing_page: { og_image: fixture_file_upload("not_an_image.txt", "text/plain") } }
    assert_response :redirect
    assert_not @landing_page.reload.og_image.attached?
  end

  test "update_og_image rejects non-admin" do
    log_in_as(@user)
    patch og_image_admin_landing_page_path(@landing_page),
      params: { landing_page: { og_image: fixture_file_upload("banner.png", "image/png") } }
    assert_response :redirect
    assert_not @landing_page.reload.og_image.attached?
  end
end
