require "test_helper"

# Turf Monster takes its link previews from studio-engine's site identity
# (docs/LINK_PREVIEW.md in the gem; /tasks/turf-adopts-link-preview). These pin
# the adoption's seams: the things that, if they drift, silently drop or double
# every unfurl while each page still renders.
class SiteIdentityAdoptionTest < ActionDispatch::IntegrationTest
  setup do
    Studio::SiteIdentity.delete_all
    @admin = users(:alex)
    @user = users(:jordan)
  end

  # --- the engine head emits the tags, so app/views must stay clean ----------

  # Under link_preview_tags = :auto the engine holds its tags off when ANY
  # template under app/views mentions og:title or og:image, a comment included,
  # and logs it once. That would silently strip every og: tag from every page
  # (the app writes none of its own now). This is the guard against a stray
  # mention coming back.
  test "no template under app/views writes or mentions its own og tags" do
    Studio.reset_link_preview_own_tags!

    assert_equal :auto, Studio.link_preview_tags,
                 "the initializer must leave link_preview_tags at :auto now that the app's own tags are gone"
    assert_nil Studio.link_preview_own_tags_file,
               "#{Studio.link_preview_own_tags_file} mentions og:title or og:image, which turns the engine's " \
               "preview tags OFF for every page. Use link_preview / content_for instead, and reword comments."
    assert Studio.link_preview_tags?, "the engine head is not emitting link-preview tags"
  ensure
    Studio.reset_link_preview_own_tags!
  end

  test "the own-tag scan the guard above relies on does find a mention" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "layouts"))
      File.write(File.join(dir, "layouts", "clean.html.erb"), "<title>x</title>")
      assert_nil Studio::LinkPreview.own_tag_file(dir)

      offender = File.join(dir, "layouts", "seo.html.erb")
      File.write(offender, "<%# writes og:image itself %>")
      assert_equal offender, Studio::LinkPreview.own_tag_file(dir)
    end
  end

  test "every page renders each preview tag exactly once" do
    get "/terms"
    assert_response :success
    %w[og:title og:description og:image og:url og:site_name].each do |property|
      assert_select "meta[property='#{property}']", count: 1
    end
    assert_select "meta[name='twitter:card'][content='summary_large_image']", count: 1
    assert_select "title", count: 1
  end

  # --- the default image lives on the public-read service ---------------------

  test "the site identity image is attached to the public og service" do
    assert_equal OgImageAttachable::PUBLIC_OG_SERVICE, Studio.link_preview_image_service
    assert_equal OgImageAttachable::PUBLIC_OG_SERVICE,
                 Studio::SiteIdentity.reflect_on_attachment(:image).options[:service_name]
  end

  # --- the drafted copy -------------------------------------------------------

  test "the drafted site copy is the old site-wide default, and names no sport" do
    assert_equal "Turf Monster — Skill-Based Pick’em Contests", Studio.site_title
    [Studio.site_title, Studio.site_description].each do |copy|
      assert_no_match(/World Cup|NFL/i, copy)
      assert_match(/skill-based/i, copy)
    end

    identity = Studio.site_identity(base_url: "https://turfmonster.media")
    assert_equal Studio.site_title, identity[:title]
    assert_equal Studio.site_description, identity[:description]
    assert_equal "https://turfmonster.media/og.png", identity[:image_url]
  end

  test "a saved site identity wins over the drafted copy" do
    Studio::SiteIdentity.current!.update!(title: "Saved Title", description: "Saved description.")
    get faucet_path
    assert_response :success
    # The faucet names its own title but no description, so the saved
    # description answers and the saved title does not.
    assert_select "meta[property='og:description'][content='Saved description.']"
    assert_select "meta[property='og:title'][content='Saved Title']", count: 0
  end

  # --- /admin/link_preview, linked from this app's admin menu ----------------

  test "an admin reaches /admin/link_preview from the admin menu" do
    log_in_as(@admin)

    get admin_hub_path
    assert_response :success
    assert_select "a[href=?]", admin_link_preview_path

    get admin_link_preview_path
    assert_response :success
  end

  test "an admin saves the default title and description at /admin/link_preview" do
    log_in_as(@admin)
    patch admin_link_preview_path, params: { site_identity: { title: "New Title", description: "New description." } }
    assert_response :see_other

    row = Studio::SiteIdentity.current
    assert_equal "New Title", row.title
    assert_equal "New description.", row.description
  end

  test "a non-admin cannot edit the link preview" do
    log_in_as(@user)
    patch admin_link_preview_path, params: { site_identity: { title: "Hijacked" } }
    assert_nil Studio::SiteIdentity.current.title
  end
end
