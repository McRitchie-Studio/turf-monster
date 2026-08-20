# View seam for the wallet-setup modal's "how do I install this?" CTA.
module WalletSetupHelper
  # Phantom's own guide — the fallback target, and a real one: it covers the
  # same install → create-a-wallet path as the house guide.
  PHANTOM_GUIDE_URL = "https://phantom.com/learn/guides/how-to-create-a-new-wallet".freeze

  # The house guide at /getting-started is the intended destination (operator
  # call, 2026-08-11) but it ships in a SEPARATE task —
  # /tasks/phantom-onboarding-guide-page, which owns the route and the page.
  #
  # So resolve it at render time instead of hard-linking a route this branch
  # does not define: if that task has landed, route helpers answer to
  # getting_started_path and users get the house guide; if it has not, they get
  # Phantom's guide rather than a 404. The check is on the ROUTE, not on a flag
  # or a date, so the CTA switches over the moment the page exists — and no
  # ordering mistake between the two tasks can ever ship a dead link.
  def wallet_setup_guide_url
    return getting_started_path if respond_to?(:getting_started_path)

    PHANTOM_GUIDE_URL
  end

  # True when the resolved guide is off-site (the fallback above), so the link
  # can open in a new tab and keep the user's lineup alive in this one.
  def wallet_setup_guide_external?
    wallet_setup_guide_url.start_with?("http")
  end

  # --- The explainer video -------------------------------------------------
  #
  # "New to Solana Wallets?" used to be two still screenshots of Phantom's
  # download and create-wallet screens. It is a video now (operator call,
  # 2026-08-18): the same three minutes, watched instead of inferred, and it
  # plays INSIDE the modal so nobody has to leave a half-finished signup to
  # learn what a wallet is.
  #
  # "How To Download and Setup Phantom Wallet on PC (Step By Step)",
  # Full Moon Finance — https://www.youtube.com/watch?v=OH7-AIjZlp4
  PHANTOM_INTRO_VIDEO_ID = "OH7-AIjZlp4".freeze

  # Self-hosted poster, NOT i.ytimg.com. It paints behind the player while the
  # iframe boots, so the block never flashes an empty black rectangle in the
  # middle of a signup — and a third-party image would be one CDN hiccup away
  # from doing exactly that. Derived from the video's own maxresdefault frame,
  # resized to 960w.
  PHANTOM_INTRO_VIDEO_POSTER = "/phantom-intro-video.jpg".freeze

  # youtube-nocookie: the privacy-mode host, so a player nobody pressed play on
  # never sets a tracking cookie for a user who is mid-signup. It is also the
  # host named in the CSP frame-src allowlist
  # (config/initializers/content_security_policy.rb) — change one and the other
  # has to move with it, or the player renders as a blocked blank frame.
  PHANTOM_INTRO_VIDEO_HOST = "https://www.youtube-nocookie.com".freeze

  # Built here rather than inline in the ERB so the query string stays out of
  # the modal's markup: it lives in a double-quoted x-data neighbourhood where a
  # bare & is an entity-parsing hazard, and CGI.escape keeps it honest.
  #
  # THE AUTOPLAY/MUTE PAIR IS ONE DECISION, NOT TWO (operator call, 2026-08-18:
  # start it playing, click to unmute). Every browser blocks autoplay WITH sound
  # unless a user gesture started it, and this modal auto-opens after auth —
  # there is no gesture to inherit. Muted autoplay is the one form that is
  # allowed, so mute=1 is what makes autoplay=1 work at all. Drop the mute and
  # the video does not start quietly; it does not start.
  #
  # enablejsapi=1 is the other half: it is what lets the modal postMessage
  # `unMute` into the player when the user clicks for sound. Without it the
  # player ignores the command and the click does nothing.
  #
  # No `origin` param. It is optional, it would have to name whichever host this
  # is running on (localhost:3120, QA, production), and getting it WRONG is
  # worse than omitting it — the player refuses commands from an origin that
  # does not match.
  def phantom_intro_video_embed_url
    query = {
      "autoplay" => "1",       # start it; the operator wants motion, not a poster
      "mute" => "1",           # ...and this is the only way autoplay is permitted
      "enablejsapi" => "1",    # so the unmute click can reach the player
      "rel" => "0",            # no end-screen grid of unrelated crypto videos
      "modestbranding" => "1",
      "playsinline" => "1"     # iOS: play in the modal, not fullscreen takeover
    }.map { |k, v| "#{k}=#{CGI.escape(v)}" }.join("&")

    "#{PHANTOM_INTRO_VIDEO_HOST}/embed/#{PHANTOM_INTRO_VIDEO_ID}?#{query}"
  end

  # The watch-on-YouTube destination, for the accessible link behind the facade.
  def phantom_intro_video_watch_url
    "https://www.youtube.com/watch?v=#{PHANTOM_INTRO_VIDEO_ID}"
  end
end
