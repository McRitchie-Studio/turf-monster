require "test_helper"

# The explainer-video seam in the wallet-setup modal's "New to Solana Wallets?"
# block. The modal renders these three strings straight into an <iframe src>,
# an <img src> and a link, and each one is a silent failure when it drifts: a
# host outside the CSP frame-src allowlist paints a blank box, a poster path
# with no file behind it paints a grey rectangle, and neither raises anything a
# render test would see.
class WalletSetupHelperTest < ActionView::TestCase
  include WalletSetupHelper

  test "the embed is built on the privacy host the CSP actually allows" do
    url = phantom_intro_video_embed_url

    assert url.start_with?("https://www.youtube-nocookie.com/embed/"),
           "the player must come from the privacy host, not youtube.com"

    # The half no assertion on this file alone can prove: the host above only
    # renders if frame-src names it. Read the policy the app really ships.
    policy = Rails.application.config.content_security_policy
    assert_includes policy.frame_src, "https://www.youtube-nocookie.com",
                    "CSP frame-src must allow the host the embed URL uses, or " \
                    "the player is a blocked blank frame with no visible error"
  end

  test "autoplay is paired with mute, because alone it does nothing" do
    query = CGI.parse(URI.parse(phantom_intro_video_embed_url).query)

    # ONE decision, not two. The modal auto-opens after auth, so there is no
    # user gesture for the player to inherit, and every browser refuses
    # autoplay WITH sound in that situation. Ship autoplay without mute and the
    # video does not start quietly — it does not start.
    assert_equal ["1"], query["autoplay"]
    assert_equal ["1"], query["mute"],
                 "autoplay without mute is blocked outright; these travel together"
  end

  test "the player accepts the unmute command the modal sends it" do
    query = CGI.parse(URI.parse(phantom_intro_video_embed_url).query)

    # The click-for-sound affordance talks to the player over postMessage. The
    # player ignores every command unless the embed opted in here, and it fails
    # SILENTLY — the overlay would disappear and the video would stay muted.
    assert_equal ["1"], query["enablejsapi"]

    # The other end of the same seam: the modal must post to the host it framed.
    modal = Rails.root.join("app/views/modals/_wallet_setup.html.erb").read
    assert_includes modal, "'https://www.youtube-nocookie.com'",
                    "postMessage must target the player's real origin"
    assert_includes modal, "'unMute'"
  end

  test "the embed keeps the onboarding-modal manners" do
    query = CGI.parse(URI.parse(phantom_intro_video_embed_url).query)

    # No end-screen grid of unrelated crypto videos inside an onboarding modal.
    assert_equal ["0"], query["rel"]
    # iOS: play in the card, not a fullscreen takeover of the signup.
    assert_equal ["1"], query["playsinline"]
    # `origin` is optional and actively harmful when wrong — a mismatched one
    # makes the player refuse the unmute command — and this app answers on
    # several hosts (localhost, QA, production).
    assert_empty query["origin"], "a hardcoded origin would break every host but one"
  end

  test "the embed points at the video the operator chose" do
    assert_equal "OH7-AIjZlp4", WalletSetupHelper::PHANTOM_INTRO_VIDEO_ID
    assert_includes phantom_intro_video_embed_url, WalletSetupHelper::PHANTOM_INTRO_VIDEO_ID
    assert_equal "https://www.youtube.com/watch?v=OH7-AIjZlp4", phantom_intro_video_watch_url
  end

  test "the poster is self-hosted and the file is really there" do
    poster = WalletSetupHelper::PHANTOM_INTRO_VIDEO_POSTER

    assert poster.start_with?("/"),
           "the poster must be served by us — it paints behind the player while " \
           "the iframe boots, and a third-party CDN hiccup would leave a black " \
           "rectangle in the middle of a signup"

    path = Rails.public_path.join(poster.delete_prefix("/"))
    assert path.exist?, "public#{poster} is missing — the modal links it"
    assert path.size.positive?, "public#{poster} is empty"
  end

  # The guide CTA seam, unchanged by the video work but adjacent to it: whichever
  # target resolves, it must be a real destination.
  test "the guide URL resolves to a real destination either way" do
    assert wallet_setup_guide_url.present?
    if Rails.application.routes.url_helpers.respond_to?(:getting_started_path)
      assert_not wallet_setup_guide_external?
    else
      assert_equal WalletSetupHelper::PHANTOM_GUIDE_URL, wallet_setup_guide_url
      assert wallet_setup_guide_external?, "an off-site guide must open in a new tab"
    end
  end
end
