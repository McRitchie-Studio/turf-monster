module ApplicationHelper
  # The contest a shared referral link should land on, resolved ONCE per request.
  #
  # WHY THIS EXISTS AS A HELPER rather than being called inline. The referral card
  # is rendered by two pages now, and only one of them has a controller that can
  # preload anything: /account set @referral_share_contest, and the engine's
  # ProfilesController — which renders the same card on /profile — cannot be made
  # to. So the partial resolves its own default, which moved the call from a
  # controller into a VIEW RENDER.
  #
  # THAT MOVE IS WHAT NEEDS CONTAINING. SeasonConfig.main_contest reaches
  # SeasonConfig.current, which is a `find_or_create_by` — normally a SELECT, but
  # a code path that can INSERT, and a view render is the wrong place to have one
  # at all. Memoising here keeps it to a single resolution per request whatever
  # renders the card, and gives the call one named home instead of being loose in
  # a template.
  #
  # `defined?` rather than `||=`, so a legitimately nil result (no open contest —
  # the off-season) is cached instead of re-queried on every call. Same idiom as
  # ApplicationController#display_seeds_data.
  def referral_share_contest
    return @_referral_share_contest if defined?(@_referral_share_contest)

    @_referral_share_contest = SeasonConfig.main_contest
  end

  # The current user's referral/invite URL landing on `target` (a same-origin
  # path, e.g. a contest). One stable Studio::Link per (user, target); the
  # tokenized /i/<token> replaces the old /contests/<slug>?ref=<slug> share link.
  # nil for a logged-out viewer.
  def referral_link_url(target)
    return unless current_user

    link_url(token: Studio::Link.referral_for(current_user, target: target).token)
  end

  # Which funding flow the entry gate offers web2 users: PayPal/Venmo when
  # explicitly selected, Stripe token packs only when the dormant fallback is
  # explicitly re-enabled, the Coinbase USDC ramp when enabled, or an honest
  # offline state otherwise. Routes modals/auth/_tokens vs _usdc_funding in
  # _auth.html.erb and the /tokens/buy page treatment.
  def entry_funding_mode
    if Payments.paypal_checkout?
      :paypal
    elsif Payments.stripe?
      :stripe
    elsif AppFlags.cdp_ramp?
      :cdp
    else
      :none
    end
  end

  CONTEST_BADGE_STYLES = {
    "open"      => "bg-mint-900/30 text-mint border-mint-700",
    "locked"    => "bg-yellow-900/50 text-yellow-400 border-yellow-700",
    "settled"   => "bg-surface-alt text-muted border-subtle",
    "pending"   => "bg-violet-900/30 text-violet border-violet-700",
    "cancelled" => "bg-red-900/30 text-red-400 border-red-700"
  }.freeze

  def contest_badge_classes(status)
    CONTEST_BADGE_STYLES[status] || ""
  end

  def dollars(amount)
    "$#{sprintf('%.2f', amount)}"
  end

  # The brand mark. Uses the lightweight 45KB icon (not the 1.3MB /logo.png) and
  # always sets explicit width/height so the box is reserved even before CSS
  # applies (no full-screen balloon on a cold load). `px` is that reserved size;
  # `classes` carry the Tailwind sizing + styling. The navbar logo stays inline
  # — it needs a scroll-responsive x-bind:class the helper can't express.
  def brand_logo(px:, classes: "")
    tag.img(src: "/icon-192.png", alt: "Turf Totals", width: px, height: px,
            class: ["rounded-full", classes].join(" ").strip)
  end

  def format_turf_score(value)
    return "—" unless value
    value == value.to_i ? value.to_i.to_s : sprintf('%.1f', value)
  end

  # Whether to load LogRocket session replay on this request. Replay runs only
  # in production AND never on pages that render secrets — a controller marks
  # those by setting @suppress_session_replay (see WalletExportsController).
  # The wallet-export reveal page renders a decrypted private key into the DOM;
  # without this gate LogRocket would stream that key (and the user's email via
  # identify()) to a third party (Lazarus audit #2, 2026-05-31).
  def session_replay_active?
    Rails.env.production? && !@suppress_session_replay
  end

  # --- LogRocket deep links (admin dashboard) ---
  # The LogRocket project the app inits with (application.html.erb). Users are
  # identify()'d by their slug, so we can deep-link a single user's sessions.
  LOGROCKET_APP_PATH = "jodsqq/mcritchie-studio".freeze

  def logrocket_sessions_url
    "https://app.logrocket.com/#{LOGROCKET_APP_PATH}/sessions"
  end
end
