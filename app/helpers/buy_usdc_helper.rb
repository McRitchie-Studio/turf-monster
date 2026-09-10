# View seam for the Get USDC modal — the teaching half of the funds wall.
#
# Sibling of WalletSetupHelper. That helper answers "how do I get a wallet?";
# this one answers the question immediately after it, "how do I get the money
# that goes in it?". The two modals are deliberately the same shape, so the
# seams are too — same guide resolution, same video query, same nocookie host.
module BuyUsdcHelper
  # Coinbase's own walkthrough — the fallback target, and a real one: it covers
  # the same buy-and-send path the Coinbase rail in Top Up Wallet takes.
  COINBASE_USDC_GUIDE_URL = "https://www.coinbase.com/learn/tips-and-tutorials/how-to-buy-usdc".freeze

  # Resolved at render time, not hard-linked, for the same reason
  # WalletSetupHelper#wallet_setup_guide_url is: /getting-started is the intended
  # house destination and it ships on its own schedule. Ask the ROUTE, so the CTA
  # switches over the moment the page exists and can never ship a dead link.
  def buy_usdc_guide_url
    return getting_started_path if respond_to?(:getting_started_path)

    COINBASE_USDC_GUIDE_URL
  end

  # True when the resolved guide is off-site, so the link opens in a new tab and
  # keeps the player's lineup alive in this one.
  def buy_usdc_guide_external?
    buy_usdc_guide_url.start_with?("http")
  end

  # --- The Phantom rail ----------------------------------------------------
  #
  # Where the row goes. Phantom exposes NO web API for "open your buy screen", so
  # a page cannot send anyone straight there; the honest destination is Phantom's
  # own site.
  #
  # THIS IS A MARKETING LANDING PAGE, NOT A UNIVERSAL LINK, and an earlier version
  # of this comment claimed otherwise while citing modals/_wallet_setup as
  # precedent. Both were wrong: _wallet_setup uses phantom.com/download, and the
  # real universal link is the phantom.app/ul/... form solana-studio's deep-link
  # partial builds. Nothing here opens an installed app — it opens a web page.
  #
  # Overridable so the operator can point it at a specific buy guide without a
  # deploy, the same way BUY_USDC_VIDEO_ID works. The default stays the bare site
  # rather than a guessed deep path: a 404 in a CTA on this card is worse than a
  # general landing page.
  PHANTOM_BUY_URL = "https://phantom.com/".freeze

  def phantom_buy_url
    ENV["PHANTOM_BUY_URL"].presence || PHANTOM_BUY_URL
  end

  # The operator's chosen walkthrough (2026-09-06). It replaced a stand-in that
  # borrowed the wallet-setup card's general Phantom video, which was honest but
  # not about buying USDC.
  DEFAULT_VIDEO_ID = "yvSwABtqGq4".freeze

  # The useful part starts here — everything before it is preamble the player
  # would otherwise make a blocked user sit through.
  DEFAULT_VIDEO_START_SECONDS = 58

  def buy_usdc_video_id
    ENV["BUY_USDC_VIDEO_ID"].presence || DEFAULT_VIDEO_ID
  end

  # A START OFFSET BELONGS TO A SPECIFIC VIDEO. 58s is where THIS video gets to
  # the point; on a replacement it would drop the viewer into the middle of
  # something else. So the default offset applies only while the default id is
  # in play — override the id alone and playback starts at 0, which is the only
  # safe assumption about a video nobody here has watched.
  def buy_usdc_video_start
    explicit = ENV["BUY_USDC_VIDEO_START"].presence
    return explicit.to_i if explicit

    buy_usdc_video_id == DEFAULT_VIDEO_ID ? DEFAULT_VIDEO_START_SECONDS : 0
  end

  # The band's player gate — and IT CANNOT RETURN FALSE, today, for any value of
  # BUY_USDC_VIDEO_ID. buy_usdc_video_id falls back to DEFAULT_VIDEO_ID above, so
  # unset/blank/whitespace resolves to "yvSwABtqGq4" and anything else resolves to
  # itself; either way `.present?` is true. There is no "no player" state to
  # design for. Sibling comments that used to imply otherwise were corrected on
  # earlier passes (modals/_buy_usdc, .env.example, admin_controller,
  # test/views/buy_usdc_modal_test); this method's own was the one left.
  #
  # Kept anyway, and not as decoration: it is the SEAM that keeps "is a video
  # configured?" one decision in one place. Views ask this, never the id, so if a
  # future operator wants a genuinely optional band the answer changes here and
  # the `if` in modals/_buy_usdc.html.erb keeps working unedited.
  def buy_usdc_video?
    buy_usdc_video_id.present?
  end

  # Same nocookie host as the wallet video, and deliberately the same constant:
  # it is the host named in the CSP frame-src allowlist
  # (config/initializers/content_security_policy.rb). A second host here would
  # render as a blocked blank frame until someone remembered the CSP.
  def buy_usdc_video_embed_url
    return nil unless buy_usdc_video?

    query = {
      "autoplay" => "1",       # start it; motion earns a glance a poster does not
      "mute" => "1",           # ...and this is the only way autoplay is permitted
      "enablejsapi" => "1",    # so the unmute click can reach the player
      "rel" => "0",            # no end-screen grid of unrelated crypto videos
      "modestbranding" => "1",
      "playsinline" => "1"     # iOS: play in the modal, not fullscreen takeover
    }
    # `start` is seconds from the beginning. Omitted entirely at 0 so the URL of
    # an un-offset video stays exactly what it was.
    query["start"] = buy_usdc_video_start.to_s if buy_usdc_video_start.positive?
    query = query.map { |k, v| "#{k}=#{CGI.escape(v)}" }.join("&")

    "#{WalletSetupHelper::PHANTOM_INTRO_VIDEO_HOST}/embed/#{CGI.escape(buy_usdc_video_id)}?#{query}"
  end

  # The watch-on-YouTube destination, for the accessible link behind the facade.
  def buy_usdc_video_watch_url
    return nil unless buy_usdc_video?

    base = "https://www.youtube.com/watch?v=#{CGI.escape(buy_usdc_video_id)}"
    buy_usdc_video_start.positive? ? "#{base}&t=#{buy_usdc_video_start}s" : base
  end
end
