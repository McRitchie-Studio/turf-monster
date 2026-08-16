module ApplicationHelper
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

  # --- Hold button "fizz" layer (shared/_hold_button) ---
  # Candy hues the bubbles pick from: TM violet through pink, then the mint /
  # cyan the success state already uses, plus one gold. Deliberately narrow —
  # the CodePen this adapts spanned the whole wheel and read as confetti; the
  # button wants carbonation that still looks like the brand.
  FIZZ_HUES = [ 262, 276, 292, 318, 336, 190, 168, 46 ].freeze

  # Deterministic bubble table for one hold button's fizz layer.
  #
  # The CodePen scattered its 52 particles with Sass `random()` at compile
  # time. Tailwind v4 gives us no Sass, and a runtime `rand` would re-scatter
  # the bubbles on every render — which fights Turbo's page cache (a restored
  # page would not match the one it replaced) and leaves the markup untestable.
  # So the scatter is SEEDED FROM hold_id: stable for a given button across
  # renders, and different between the board's "desktop" and "mobile" buttons.
  #
  # Each bit is one bubble. x/y place it in the button's box (%), dx/dy are the
  # drift it travels before fading (dy negative = rises off the top edge), size
  # is px, delay/duration are seconds, hue indexes FIZZ_HUES. The CSS scales
  # dx/dy up per state — a fraction while idle, full while held, ~2.6x on the
  # success burst — so one table drives every phase.
  def hold_button_fizz_bits(hold_id, count: 26)
    prng = Random.new(hold_id.to_s.each_byte.sum * 7919 + count)

    Array.new(count) do |i|
      # 4-in-10 along the bottom edge, 4-in-10 along the top, 1 off each end.
      case i % 10
      when 0, 1, 2, 3 then bottom_fizz_bit(prng)
      when 4, 5, 6, 7 then top_fizz_bit(prng)
      when 8          then side_fizz_bit(prng, :left)
      else                 side_fizz_bit(prng, :right)
      end
    end
  end

  private

  def bottom_fizz_bit(prng)
    fizz_bit(prng, x: 4 + prng.rand(92), y: 86 + prng.rand(12),
                   dx: prng.rand(-8..8), dy: 12 + prng.rand(24))
  end

  def top_fizz_bit(prng)
    fizz_bit(prng, x: 4 + prng.rand(92), y: 2 + prng.rand(12),
                   dx: prng.rand(-8..8), dy: -(12 + prng.rand(24)))
  end

  def side_fizz_bit(prng, side)
    reach = 10 + prng.rand(18)
    fizz_bit(prng,
             x: side == :left ? prng.rand(5) : 95 + prng.rand(5),
             y: 18 + prng.rand(64),
             dx: side == :left ? -reach : reach,
             dy: prng.rand(-6..6))
  end

  def fizz_bit(prng, x:, y:, dx:, dy:)
    { x: x, y: y, dx: dx, dy: dy,
      size: 2 + prng.rand(5),
      delay: (prng.rand(180) / 100.0).round(2),
      duration: (1.4 + prng.rand(120) / 100.0).round(2),
      hue: FIZZ_HUES[prng.rand(FIZZ_HUES.size)] }
  end
end
