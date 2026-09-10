require "test_helper"

# [unit] The Get USDC modal's video and guide seams.
#
# Sibling of WalletSetupHelperTest, guarding the same class of silent failure:
# these strings land straight in an <iframe src> and an <a href>, and each one
# fails quietly when it drifts — a host outside the CSP frame-src allowlist
# paints a blank box, and nothing raises.
class BuyUsdcHelperTest < ActionView::TestCase
  include BuyUsdcHelper

  def with_video_id(id)
    was = ENV["BUY_USDC_VIDEO_ID"]
    ENV["BUY_USDC_VIDEO_ID"] = id
    yield
  ensure
    ENV["BUY_USDC_VIDEO_ID"] = was
  end

  # --- the video, and the offset that belongs to it ---------------------------
  #
  # The card no longer borrows the wallet-setup walkthrough. It plays the
  # operator's own USDC video from the point it gets useful.

  test "the default is the operator's video, started where it gets to the point" do
    with_video_id(nil) do
      assert_equal DEFAULT_VIDEO_ID, buy_usdc_video_id
      assert_equal 58, buy_usdc_video_start
      assert_includes buy_usdc_video_embed_url, "start=58"
      assert_includes buy_usdc_video_watch_url, "&t=58s",
                      "the read-it-elsewhere link must land in the same place"
    end
  end

  test "an OVERRIDDEN id does not inherit the offset" do
    # 58s is where THIS video gets to the point. On a replacement it would drop
    # the viewer into the middle of something else, so the default offset applies
    # only while the default id is in play. This is the coupling worth pinning.
    with_video_id("abc123XYZ_-") do
      assert_equal "abc123XYZ_-", buy_usdc_video_id
      assert_equal 0, buy_usdc_video_start
      refute_includes buy_usdc_video_embed_url, "start=",
                      "a start offset from a different video is worse than none"
      refute_includes buy_usdc_video_watch_url, "&t="
    end
  end

  test "an explicit offset wins for any id" do
    with_video_id("abc123XYZ_-") do
      was = ENV["BUY_USDC_VIDEO_START"]
      ENV["BUY_USDC_VIDEO_START"] = "12"
      assert_equal 12, buy_usdc_video_start
      assert_includes buy_usdc_video_embed_url, "start=12"
    ensure
      was.nil? ? ENV.delete("BUY_USDC_VIDEO_START") : ENV["BUY_USDC_VIDEO_START"] = was
    end
  end

  test "a blank id falls back to the default, not to an empty embed" do
    with_video_id("  ") do
      assert buy_usdc_video?
      assert_equal DEFAULT_VIDEO_ID, buy_usdc_video_id
    end
  end

  # --- the embed, once the operator supplies one ------------------------------

  test "the embed is built on the privacy host the CSP actually allows" do
    with_video_id("abc123XYZ_-") do
      url = buy_usdc_video_embed_url

      assert url.start_with?("https://www.youtube-nocookie.com/embed/abc123XYZ_-?"),
             "the player must come from the privacy host, not youtube.com"

      # The half no assertion on this file alone can prove: the host above only
      # renders if frame-src names it. Read the policy the app really ships.
      # READ THE DIRECTIVE, DO NOT CALL THE DSL METHOD. In Rails'
      # ActionDispatch::ContentSecurityPolicy every directive is `def frame_src(*sources)`
      # — a SETTER. Calling it with no arguments returns the current list AND
      # assigns nil, so the first caller in a process reads the real value and
      # DESTROYS it for everyone after. Measured 2026-09-05: this file's own
      # assertion wiped frame-src, and the sibling BuyUsdcHelperTest then failed on
      # `Expected nil (NilClass) to respond to #include?` — green alone, red in the
      # suite, and the mutation leaks to any later test that renders under this CSP.
      frame_src = Rails.application.config.content_security_policy.directives["frame-src"]
      assert_includes frame_src, "https://www.youtube-nocookie.com",
                      "CSP frame-src must allow the host the embed URL uses, or " \
                      "the player is a blocked blank frame with no visible error"
    end
  end

  test "autoplay is paired with mute, because alone it does nothing" do
    with_video_id("abc123XYZ_-") do
      query = CGI.parse(URI.parse(buy_usdc_video_embed_url).query)

      # ONE decision, not two. This modal opens from the entry blocker without a
      # click, so there is no user gesture for the player to inherit, and every
      # browser refuses autoplay with sound. Drop the mute and the video does not
      # start quietly — it does not start.
      assert_equal ["1"], query["autoplay"]
      assert_equal ["1"], query["mute"]
      # The other half of the tap-for-sound affordance: without enablejsapi the
      # player ignores the unMute postMessage and the click does nothing.
      assert_equal ["1"], query["enablejsapi"]
      assert_equal ["1"], query["playsinline"]
    end
  end

  test "the host constant is shared with the wallet video, not re-declared" do
    # A second host constant here is how one of them drifts out of the CSP
    # allowlist while the other stays in it. Pin that this helper builds on the
    # wallet card's constant rather than a copy of its value.
    with_video_id("abc123XYZ_-") do
      assert buy_usdc_video_embed_url.start_with?(WalletSetupHelper::PHANTOM_INTRO_VIDEO_HOST),
             "both videos must resolve through one host constant"
    end
  end

  # --- the guide --------------------------------------------------------------

  test "the guide resolves to the house page when the route exists" do
    # Resolved on the ROUTE, not a flag, so the CTA switches over the moment the
    # page ships and no ordering mistake can leave a dead link behind.
    assert respond_to?(:getting_started_path),
           "this app defines getting-started; if that changes the helper falls " \
           "back to Coinbase's guide rather than 404ing"
    assert_equal getting_started_path, buy_usdc_guide_url
    refute buy_usdc_guide_external?, "an internal guide must not open in a new tab"
  end
end
