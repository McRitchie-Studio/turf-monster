require "test_helper"

# [component] The contest banner's crop ratio (task: banner-crop-five-to-one).
#
# The crop paradigm moved 4:1 -> 5:1. Three places declare it, and a build that
# moves only some of them is the failure this pins: the /contests/new cropper,
# the /contests/:id/edit cropper, and the edit screen's preview box. The two
# croppers are asserted as a PAIR, because a contest created at 5:1 and then
# re-cropped at 4:1 on the editor is the same regression as the reverse.
#
# The fourth assertion is the other half of the operator's ask: banners already
# stored at 4:1 must still display gracefully. The preview box is the ONLY
# ratio-locked banner surface in the app -- _hero and _contest_card both pin a
# fixed height and object-cover, so they crop any ratio and always did -- so the
# box tracks the stored image's own ratio instead of squeezing a legacy banner
# into the new one.
class ContestBannerCropRatioTest < ActionDispatch::IntegrationTest
  # Anchored on the WHOLE banner declaration, not on `aspectRatio:` alone. The
  # engine's crop modal ships a usage comment carrying a literal
  # `aspectRatio: 3, maxWidth: 900, maxHeight: 300`, which renders into the same
  # page -- so a bare `aspectRatio: N` probe reads engine prose as easily as the
  # contest's own config, and would pass on a build where only a comment moved.
  BANNER_CROP  = /aspectRatio:\s*5,\s*maxWidth:\s*2000,\s*maxHeight:\s*400/
  RETIRED_CROP = /aspectRatio:\s*4,\s*maxWidth:\s*2000/

  setup do
    @contest = contests(:one)
    SeasonConfig.set_current!(1)
    log_in_as(users(:alex)) # banner editing is admin-only
  end

  # --- the crop declaration ---------------------------------------------

  test "[component] the contest editor's cropper crops at 5:1" do
    get edit_contest_path(@contest)

    assert_response :success
    assert_match(BANNER_CROP, response.body,
      "the edit-screen imageUploadHost must crop at 5:1")
    assert_no_match(RETIRED_CROP, response.body,
      "the retired 4:1 crop must not survive on the editor")
  end

  test "[component] the new-contest cropper crops at 5:1" do
    get new_contest_path

    assert_response :success
    assert_match(BANNER_CROP, response.body,
      "contestBannerCrop must open the shared modal at 5:1")
    assert_no_match(RETIRED_CROP, response.body,
      "the retired 4:1 crop must not survive on contest creation")
  end

  # --- the preview box ---------------------------------------------------

  test "[component] the empty preview box holds the 5:1 crop shape" do
    assert_not @contest.contest_image.attached?, "fixture must start bannerless"

    get edit_contest_path(@contest)

    assert_response :success
    assert_select "#contest-banner-preview[style*='aspect-ratio: 5 / 1']", count: 1
  end

  # A banner cropped under the old paradigm. Its metadata is written directly
  # rather than analyzed, so the assertion does not depend on an image backend
  # being installed on the runner -- the INPUT is a legacy 4:1 blob either way.
  test "[component] a legacy 4:1 banner previews at its own stored ratio" do
    attach_banner(width: 1668, height: 417) # a real 4:1 production banner

    get edit_contest_path(@contest)

    assert_response :success
    assert_select "#contest-banner-preview[style*='aspect-ratio: 1668 / 417']", count: 1
    assert_select "#contest-banner-preview[style*='aspect-ratio: 5 / 1']", count: 0,
      message: "a stored 4:1 banner must not be squeezed into the 5:1 box"
  end

  # An attachment whose AnalyzeJob has not run carries no width/height. The box
  # has nothing to track, so it falls back to the current crop shape.
  test "[component] an unanalyzed banner falls back to the 5:1 crop shape" do
    attach_banner(width: nil, height: nil)

    get edit_contest_path(@contest)

    assert_response :success
    assert_select "#contest-banner-preview[style*='aspect-ratio: 5 / 1']", count: 1
  end

  private

  def attach_banner(width:, height:)
    @contest.contest_image.attach(
      io: File.open(Rails.root.join("test/fixtures/files/banner.png")),
      filename: "banner.png", content_type: "image/png"
    )
    metadata = { "identified" => true, "analyzed" => true }
    metadata.merge!("width" => width, "height" => height) if width && height
    @contest.contest_image.blob.update!(metadata: metadata)
    @contest.reload
  end
end
