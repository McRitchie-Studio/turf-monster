require "test_helper"

class OgHelperTest < ActionView::TestCase
  include OgHelper

  setup do
    # Disk (test) service .url needs a host to build the blob URL.
    ActiveStorage::Current.url_options = { host: "test.host", protocol: "http" }
  end

  # --- contest_og_image_url (the contest rung) ---

  test "contest_og_image_url is nil when there is no contest or no banner" do
    assert_nil contest_og_image_url(nil)
    assert_nil contest_og_image_url(contests(:one)),
               "an unbannered contest must fall through to the site default, not blank the card"
  end

  test "contest_og_image_url serves the banner card through the proxy route" do
    contest = contests(:one)
    contest.contest_image.attach(
      io: file_fixture("banner_wide.png").open, filename: "banner.png", content_type: "image/png"
    )

    url = contest_og_image_url(contest)

    assert url.start_with?("http"), "expected an absolute url, got #{url}"
    # THE ROUTE IS THE POINT, not just that a url came back. contest_image lives
    # on the private service, whose own url is a signature that expires — and an
    # unfurler caches the og:image url it was handed and re-fetches it days
    # later. The representation PROXY route is permanent (the signed blob id
    # carries no expiry) and streams from that same private bucket.
    assert_includes url, "/representations/proxy/"
    assert_not_includes url, "/redirect/",
                        "the redirect route hands back an expiring service url — the preview would break later"
  end

  # REGRESSION (review, 2026-09-09): `.variant` raises InvariableError EAGERLY on
  # a blob outside ActiveStorage.variable_content_types, so an attached?-only
  # guard 500s contests#show for every visitor — and "/" when that contest is
  # featured. attach_contest_banner (finalize) has no valid_image? gate, so an
  # svg banner reaches the page. Falling through to nil is the pre-existing
  # behavior: site-default card, broken hero image, page still served.
  test "contest_og_image_url falls through when the banner cannot be varied" do
    contest = contests(:one)
    contest.contest_image.attach(
      io: StringIO.new(%(<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"></svg>)),
      filename: "banner.svg", content_type: "image/svg+xml"
    )

    assert_not contest.contest_image.variable?, "fixture must be a non-variable blob for this to bite"
    assert_nothing_raised { contest_og_image_url(contest) }
    assert_nil contest_og_image_url(contest),
               "a non-variable banner must fall through to the site default, not raise on a public page"
  end

  test "contest_og_image_url points at the og_card variant, not the raw banner" do
    contest = contests(:one)
    contest.contest_image.attach(
      io: file_fixture("banner_wide.png").open, filename: "banner.png", content_type: "image/png"
    )

    # A representation url carries a variation key; a plain blob url does not.
    # Handing over the raw 5:1 banner is the regression this catches.
    assert_no_match %r{/blobs/proxy/}, contest_og_image_url(contest)
  end

  # --- contest preview copy (contest pages set these as :title and
  #     :meta_description so a shared link previews as the contest) ---

  test "contest_og_title names the contest" do
    assert_equal "Test Contest — Turf Monster", contest_og_title(contests(:one))
  end

  test "contest_og_description leads with the tagline and states the money line" do
    contest = contests(:one)
    contest.tagline = "Weeks 4-6 on the NFL slate"
    description = contest_og_description(contest)

    assert description.start_with?("Weeks 4-6 on the NFL slate: $#{contest.guaranteed_prize_dollars.to_i} in prizes, $19 entry.")
    assert_not_includes description, "World Cup"
  end

  test "contest_og_description falls back to the name and calls a free contest free" do
    contest = contests(:one)
    contest.tagline = nil
    contest.entry_fee_cents = 0

    assert_includes contest_og_description(contest), "Test Contest: "
    assert_includes contest_og_description(contest), "free to enter"
    assert_not_includes contest_og_description(contest), "$0 entry"
  end
end
