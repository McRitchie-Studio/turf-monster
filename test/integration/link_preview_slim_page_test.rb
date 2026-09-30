require "test_helper"

# Apple's LinkPresentation (the iMessage unfurler) aborts any page over 1 MiB
# with WebKit 102 "Frame load interrupted", and a production contest page was
# 1,224,381 bytes, so contest links never previewed in Messages. Preview bots
# now get a slim document of just the identity/og tags; people keep the full
# page. See LinkPreviewBot and layouts/_link_preview_document.
class LinkPreviewSlimPageTest < ActionDispatch::IntegrationTest
  LINK_PRESENTATION_LIMIT = 1_048_576 # measured: 1,048,000 bytes previews, 1,049,000 fails

  IMESSAGE = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_1) AppleWebKit/601.2.4 " \
             "(KHTML, like Gecko) Version/9.0.1 Safari/601.2.4 facebookexternalhit/1.1 " \
             "Facebot Twitterbot/1.0".freeze
  DISCORD = "Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)".freeze
  IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 " \
           "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1".freeze

  # Present only in the full application layout: the session store's JSON seed.
  FULL_PAGE_MARKER = 'id="session-context"'.freeze

  setup do
    SiteSetting.instance.update!(default_og_title: nil, default_og_description: nil)
    SiteSetting.instance.default_og_image.purge if SiteSetting.instance.default_og_image.attached?
    @contest = contests(:one)
  end

  def get_contest_as(user_agent, contest = @contest)
    get contest_path(contest), headers: { "HTTP_USER_AGENT" => user_agent }
    assert_response :success
    response.body
  end

  test "iMessage gets a slim page under the LinkPresentation limit with the contest's own tags" do
    body = get_contest_as(IMESSAGE)

    assert_operator body.bytesize, :<, LINK_PRESENTATION_LIMIT
    assert_not_includes body, FULL_PAGE_MARKER, "a preview bot must not get the full app page"
    assert_select "title", text: "#{@contest.name} — Turf Monster"
    assert_select "meta[property='og:title'][content=?]", "#{@contest.name} — Turf Monster"
    assert_select "meta[property='og:image']" do |tags|
      assert tags.first["content"].end_with?("/og.png"), "an unbannered contest keeps the /og.png fallback"
    end
    assert_select "meta[property='og:description']" do |tags|
      assert_includes tags.first["content"], @contest.name
      assert_includes tags.first["content"], "$19 entry"
    end
    assert_select "meta[name='twitter:card'][content='summary_large_image']"
    assert_select "link[rel='apple-touch-icon']"
    assert_select "body h1", text: "#{@contest.name} — Turf Monster"
    assert_select "script", count: 0
    assert_select "template", count: 0
  end

  test "the slim page is a small fraction of the full page a person gets for the same contest" do
    bot_body = get_contest_as(IMESSAGE)
    human_body = get_contest_as(IPHONE)

    # Measured, not asserted to exceed 1 MiB: the fixture contest's full page is
    # about 920 KB here (production's was 1.22 MB). The ratio is what the slim
    # path owns.
    assert_operator human_body.bytesize, :>, bot_body.bytesize * 20,
                    "full page #{human_body.bytesize} bytes vs slim #{bot_body.bytesize} bytes"
  end

  test "a person gets the full contest page with the contest's own title" do
    body = get_contest_as(IPHONE)

    assert_includes body, FULL_PAGE_MARKER
    assert_select "title", text: "#{@contest.name} — Turf Monster"
    assert_select "meta[property='og:title'][content=?]", "#{@contest.name} — Turf Monster"
  end

  test "a bannered contest gives the slim page its own banner, not the site default" do
    SiteSetting.instance.default_og_image.attach(
      io: file_fixture("banner.png").open, filename: "site-og.png", content_type: "image/png"
    )
    @contest.contest_image.attach(
      io: file_fixture("banner_wide.png").open, filename: "contest-banner.png", content_type: "image/png"
    )

    body = get_contest_as(DISCORD)

    assert_not_includes body, FULL_PAGE_MARKER
    assert_select "meta[property='og:image']" do |tags|
      assert_includes tags.first["content"], "/representations/proxy/"
    end
    assert_select "meta[property='og:image:width']", count: 0
  end

  test "the root redirect lands a preview bot on the slim contest page" do
    get root_path, headers: { "HTTP_USER_AGENT" => IMESSAGE }
    assert_response :redirect
    follow_redirect!(headers: { "HTTP_USER_AGENT" => IMESSAGE })

    assert_response :success
    assert_operator response.body.bytesize, :<, LINK_PRESENTATION_LIMIT
    assert_not_includes response.body, FULL_PAGE_MARKER
    assert_select "meta[property='og:title']"
  end

  test "a non-contest page on the application layout also goes slim for a bot" do
    get "/terms", headers: { "HTTP_USER_AGENT" => IMESSAGE }
    assert_response :success
    assert_not_includes response.body, FULL_PAGE_MARKER
    assert_select "meta[property='og:image']"
  end
end
