require "test_helper"

# End-to-end wiring: the og:image/title/description that OgHelper resolves
# actually reach the rendered <head> in BOTH layouts (application + landing).
class OgMetaTest < ActionDispatch::IntegrationTest
  setup do
    SiteSetting.instance.update!(default_og_title: nil, default_og_description: nil)
    SiteSetting.instance.default_og_image.purge if SiteSetting.instance.default_og_image.attached?
  end

  def og_image_content
    css_select("meta[property='og:image']").first["content"]
  end

  # --- application layout (faucet is a public GET on the app layout) ---

  test "application layout falls back to the static og.png by default" do
    get faucet_path
    assert_response :success
    assert og_image_content.end_with?("/og.png"), "expected static fallback, got #{og_image_content}"
    # Static fallback is the only case that emits fixed dimensions.
    assert_select "meta[property='og:image:width'][content='1200']"
  end

  test "application layout uses the SiteSetting default image when one is uploaded" do
    SiteSetting.instance.default_og_image.attach(
      io: file_fixture("banner.png").open, filename: "site-og.png", content_type: "image/png"
    )
    get faucet_path
    assert_response :success
    assert_not og_image_content.end_with?("/og.png"), "expected the uploaded default, got the static fallback"
    # Uploaded images have unknown dimensions — no fixed width/height emitted.
    assert_select "meta[property='og:image:width']", count: 0
  end

  test "admin-set default description fills in; a page's own title still wins" do
    SiteSetting.instance.update!(
      default_og_title: "Admin Title", default_og_description: "Admin Description"
    )
    get faucet_path
    assert_response :success
    # Faucet sets its own title (page-specific wins over the site default) but
    # no description, so the admin-set default description fills in.
    assert_select "meta[property='og:description'][content='Admin Description']"
    assert_select "meta[property='og:title'][content='Devnet Faucet — Turf Monster']"
    assert_select "meta[property='og:title'][content='Admin Title']", count: 0
  end

  # --- contest pages (the contest's own banner wins) ---

  # A second contest to pin. Built here rather than added to contests.yml: the
  # fixture set is counted by other tests, and a new row there changes what they
  # see. `dup` carries none of the original's attachments.
  def another_contest
    contests(:one).dup.tap do |contest|
      contest.name = "Second Test Contest"
      contest.slug = "second-test-contest"
      contest.rank = 200
      contest.save!
    end
  end

  def attach_banner(contest, filename)
    contest.contest_image.attach(
      io: file_fixture("banner_wide.png").open, filename: filename, content_type: "image/png"
    )
    contest
  end

  test "a contest unfurls with its own banner, composed into the card" do
    SiteSetting.instance.default_og_image.attach(
      io: file_fixture("banner.png").open, filename: "site-og.png", content_type: "image/png"
    )
    contest = attach_banner(contests(:one), "contest-banner.png")

    get contest_path(contest)
    assert_response :success
    # The banner is served as the :og_card variant through the permanent proxy
    # route — not the site default, and not the raw blob.
    assert_includes og_image_content, "/representations/proxy/"
    assert_not_includes og_image_content, "site-og.png"
    # An upload of composed size must not claim the static default's dimensions.
    assert_select "meta[property='og:image:width']", count: 0
  end

  test "a contest with no banner still falls back to the site default" do
    get contest_path(contests(:one))
    assert_response :success
    assert og_image_content.end_with?("/og.png"),
           "an unbannered contest must keep the existing fallback, got #{og_image_content}"
  end

  # --- the root url (which is a redirect, not a page) ---

  test "the root url unfurls with the pinned contest's banner" do
    # "/" is ContestsController#world_cup: it renders nothing and 302s to
    # Contest.featured, which leads with the contest an admin pinned at
    # /admin/dashboard. An unfurler follows that redirect and reads the page it
    # lands on, so the pinned contest's banner IS the card for a bare
    # turfmonster.media link — and re-pinning changes it with no deploy.
    pinned = attach_banner(another_contest, "pinned-banner.png")
    SeasonConfig.set_main_contest!(pinned)

    get root_path
    assert_redirected_to contest_path(pinned)
    follow_redirect!

    assert_response :success
    assert_includes og_image_content, "/representations/proxy/"
  end

  test "re-pinning moves the root card to the newly pinned contest" do
    first  = attach_banner(contests(:one), "first-banner.png")
    second = attach_banner(another_contest, "second-banner.png")

    SeasonConfig.set_main_contest!(first)
    get root_path
    follow_redirect!
    first_card = og_image_content

    SeasonConfig.set_main_contest!(second)
    get root_path
    follow_redirect!

    assert_not_equal first_card, og_image_content,
                     "the root card must follow the pin, not freeze on the first contest"
  end

  # --- landing layout (per-page override wins) ---

  test "landing layout uses the per-page og image over the site default" do
    SiteSetting.instance.default_og_image.attach(
      io: file_fixture("banner.png").open, filename: "site-og.png", content_type: "image/png"
    )
    lp = landing_pages(:launch)
    lp.og_image.attach(
      io: file_fixture("banner_wide.png").open, filename: "page-og.png", content_type: "image/png"
    )

    get landing_page_path(lp)
    assert_response :success
    # The Disk (test) redirect URL ends with the blob filename — assert the
    # per-page blob won over the site default (avoids signature/host timing
    # flakiness from comparing freshly-signed URLs).
    assert_includes og_image_content, "page-og.png"
    assert_not_includes og_image_content, "site-og.png"
  end

  test "landing layout falls back to the static og.png when nothing is uploaded" do
    get landing_page_path(landing_pages(:launch))
    assert_response :success
    assert og_image_content.end_with?("/og.png")
  end
end
