require "test_helper"

# End-to-end wiring: the link-preview image, title and description resolved by
# studio-engine (the page override, then Studio::SiteIdentity, then the drafted
# copy and the static /og.png) actually reach the rendered <head> in BOTH
# layouts (application + landing), exactly once.
class OgMetaTest < ActionDispatch::IntegrationTest
  setup do
    Studio::SiteIdentity.delete_all
  end

  def og_image_content
    tags = css_select("meta[property='og:image']")
    assert_equal 1, tags.size, "expected exactly one og:image tag, got #{tags.size}"
    tags.first["content"]
  end

  def attach_site_image(filename = "site-og.png")
    Studio::SiteIdentity.current!.image.attach(
      io: file_fixture("banner.png").open, filename: filename, content_type: "image/png"
    )
  end

  # --- application layout (faucet is a public GET on the app layout) ---

  test "application layout falls back to the static og.png by default" do
    get faucet_path
    assert_response :success
    assert og_image_content.start_with?("http"), "og:image must be absolute, got #{og_image_content}"
    assert og_image_content.end_with?("/og.png"), "expected static fallback, got #{og_image_content}"
    # With nothing saved, the drafted copy in the studio initializer answers.
    assert_select "meta[property='og:description'][content=?]", Studio.site_description
  end

  test "application layout uses the site identity image when one is uploaded" do
    attach_site_image
    get faucet_path
    assert_response :success
    assert og_image_content.start_with?("http"), "og:image must be absolute, got #{og_image_content}"
    assert_includes og_image_content, "site-og.png"
  end

  test "operator-set default description fills in; a page's own title still wins" do
    Studio::SiteIdentity.current!.update!(title: "Admin Title", description: "Admin Description")
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
    attach_site_image
    contest = attach_banner(contests(:one), "contest-banner.png")

    get contest_path(contest)
    assert_response :success
    # The banner is served as the :og_card variant through the permanent proxy
    # route — not the site default, and not the raw blob.
    assert_includes og_image_content, "/representations/proxy/"
    assert_not_includes og_image_content, "site-og.png"
  end

  test "a contest with no banner falls back to the site identity image" do
    attach_site_image
    get contest_path(contests(:one))
    assert_response :success
    assert_includes og_image_content, "site-og.png",
                    "an unbannered contest must unfurl with the site identity's image"
    # ...while keeping its own words.
    assert_select "meta[property='og:title'][content=?]", "#{contests(:one).name} — Turf Monster"
  end

  test "a contest with no banner and no site image keeps the static fallback" do
    get contest_path(contests(:one))
    assert_response :success
    assert og_image_content.end_with?("/og.png"),
           "an unbannered contest must keep the existing fallback, got #{og_image_content}"
  end

  # --- the root url (the contests lobby) ---

  test "the root url unfurls with the pinned contest's banner" do
    # "/" is the contests lobby, and its og:image is Contest.featured's banner,
    # which leads with the contest an admin pinned at /admin/dashboard. So the
    # pinned contest's banner IS the card for a bare turfmonster.media link, and
    # re-pinning changes it with no deploy.
    pinned = attach_banner(another_contest, "pinned-banner.png")
    SeasonConfig.set_main_contest!(pinned)

    get root_path

    assert_response :success
    assert_includes og_image_content, "/representations/proxy/"
  end

  test "re-pinning moves the root card to the newly pinned contest" do
    first  = attach_banner(contests(:one), "first-banner.png")
    second = attach_banner(another_contest, "second-banner.png")

    SeasonConfig.set_main_contest!(first)
    get root_path
    first_card = og_image_content

    SeasonConfig.set_main_contest!(second)
    get root_path

    assert_not_equal first_card, og_image_content,
                     "the root card must follow the pin, not freeze on the first contest"
  end

  # --- landing layout (per-page override wins) ---

  test "landing layout uses the per-page og image over the site default" do
    attach_site_image
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

  test "landing layout falls back to the site identity image when the page has none" do
    attach_site_image
    get landing_page_path(landing_pages(:launch))
    assert_response :success
    assert_includes og_image_content, "site-og.png"
  end

  test "landing layout falls back to the static og.png when nothing is uploaded" do
    get landing_page_path(landing_pages(:launch))
    assert_response :success
    assert og_image_content.end_with?("/og.png")
  end

  # --- pages that used to write their own tags now override through the engine ---

  test "the contract page unfurls with its own description and the site image" do
    get contract_path
    assert_response :success
    assert_select "meta[property='og:title'][content='The Contract — Turf Monster']"
    assert_select "meta[property='og:description']" do |tags|
      assert_equal 1, tags.size
      assert_includes tags.first["content"], "The exact smart contract"
    end
    assert og_image_content.end_with?("/og.png"), "the 1.3 MB /logo.png is no longer the card"
  end
end
