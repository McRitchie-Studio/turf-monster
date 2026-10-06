require "test_helper"

# GET /tiktok — the spoken-aloud funnel URL ("type turfmonster.media/tiktok").
# It must attribute the visitor to the channel whether or not the operator has
# published the tiktok landing page yet, and it must never 500.
class LandingPagesVanityTest < ActionDispatch::IntegrationTest
  def tiktok_page(active: true)
    LandingPage.create!(name: "TikTok Free Entry", slug: "tiktok",
                        headline: "Free entry for TikTok followers",
                        contest: contests(:one), active: active)
  end

  test "/tiktok routes to the vanity action with the tiktok slug" do
    assert_recognizes({ controller: "landing_pages", action: "vanity", slug: "tiktok" }, "/tiktok")
  end

  test "an active tiktok page: /tiktok redirects to /lp/tiktok" do
    tiktok_page

    get "/tiktok"

    assert_response :found # 302, never 301 — the answer changes when the page does
    assert_redirected_to landing_page_path("tiktok")
  end

  test "the query string survives the hop to the landing page" do
    tiktok_page

    get "/tiktok", params: { utm_source: "tiktok", utm_content: "video-12" }

    assert_redirected_to landing_page_path("tiktok", utm_source: "tiktok", utm_content: "video-12")
  end

  test "following the hop tags the visitor with reference=tiktok" do
    tiktok_page

    get "/tiktok"
    follow_redirect!

    assert_response :success
    assert_equal "tiktok", cookies[:reference]
  end

  test "no tiktok page: falls back to the home page carrying reference=tiktok" do
    assert_nil LandingPage.find_by(slug: "tiktok")

    get "/tiktok"

    assert_response :found
    assert_redirected_to root_path(reference: "tiktok")
  end

  test "the fallback still attributes the visitor to tiktok" do
    get "/tiktok"
    follow_redirect!

    assert_equal "tiktok", cookies[:reference]
  end

  test "the fallback keeps the query string alongside the reference" do
    get "/tiktok", params: { utm_content: "video-12" }

    assert_redirected_to root_path(reference: "tiktok", utm_content: "video-12")
  end

  test "an explicit ?reference= in the link wins over the slug on the fallback" do
    get "/tiktok", params: { reference: "tiktok-bio" }

    assert_redirected_to root_path(reference: "tiktok-bio")
  end

  test "an explicit ?r= in the link wins over the slug on the fallback" do
    get "/tiktok", params: { r: "tiktok-bio" }

    assert_redirected_to root_path(reference: "tiktok", r: "tiktok-bio")
    follow_redirect!
    assert_equal "tiktok-bio", cookies[:reference], "r outranks the slug's reference on the landing"
  end

  test "an inactive tiktok page falls back for the public" do
    tiktok_page(active: false)

    get "/tiktok"

    assert_redirected_to root_path(reference: "tiktok")
  end

  test "an inactive tiktok page still previews for an admin" do
    tiktok_page(active: false)
    log_in_as(users(:alex))

    get "/tiktok"

    assert_redirected_to landing_page_path("tiktok")
  end
end
