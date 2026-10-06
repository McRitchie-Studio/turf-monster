class PagesController < ApplicationController
  skip_before_action :require_authentication

  def turf_totals_v1
  end

  # NFL-season rules page. Sibling of #turf_totals_v1 (World Cup) — same shape,
  # different sport: linear multiplier curve, points scored rather than goals,
  # and a multi-week span slate.
  #
  # Loads the Team rows the page's worked examples name so its cards wear the
  # SAME brand colors the real board does (TeamColorsHelper#team_card_palette),
  # rather than a hand-painted imitation that drifts the first time a team's
  # palette is tuned. One query for all 18 teams — the six picks, their
  # opponents (whose chips wear their own color), and the three curve rows.
  # Missing rows are survivable: the palette helper is nil-safe and falls back
  # to a neutral field, so the page degrades to grey rather than 500ing.
  def turf_monster_v1
    @teams = Team.where(slug: TurfMonsterRules.team_slugs).index_by(&:slug)
  end

  # The explainer that will become /about (top of the funnel): what the game
  # is, the countdown to the next slate drop, a notify-me form, and how to play.
  # Its two phone mockups draw the SAME team cards v1 does (the hero phone with
  # TurfMonsterRules::SHOWCASE's six), so it loads their Team rows the same way
  # — one query, nil-safe when rows are missing.
  #
  # @drop_signup_status is the no-JS round trip: a plain form post redirects
  # back here with flash[:drop_signup] ("ok" / "invalid"), and the form draws
  # its success or error state from it on the first paint.
  #
  # @next_contest is the page's one call to action (NextContest): a link to
  # the next contest still open to enter, or the notify-me modal. @lobby is
  # what the hero's laptop shows: a contest's live page when one is being
  # played or just finished (@live_showcase), else the lobby rows.
  def turf_monster_v2
    slugs = TurfMonsterRules.team_slugs | TurfMonsterRules.showcase_team_slugs
    @teams = Team.where(slug: slugs).index_by(&:slug)
    @drop_signup_status = flash[:drop_signup]
    @next_contest = NextContest.pick
    @lobby = NextContest.lobby
    @live_showcase = NextContest.live_showcase
    @hover_slug = TurfMonsterRules.showcase_hover_slug
    @laptop_live_html = @live_showcase && LaptopLiveSnapshot.render(@live_showcase, host: request.host_with_port, https: request.ssl?)
  end

  def terms
    # The Terms' state-eligibility section renders the LIVE enforcement list
    # (same source as /state-eligibility) so policy can't drift from the gate.
    @excluded_states = Studio::GeoSetting.banned_subdivision_codes
  end

  def privacy
  end

  def about
  end

  def contact
  end

  # Underwriting compliance: published state-eligibility policy, rendered
  # from Studio::GeoSetting (the IP-geolocation enforcement source of truth).
  def state_eligibility
    @excluded_states = Studio::GeoSetting.banned_subdivision_codes
  end

  # Underwriting compliance: responsible-gaming / play-responsibly resources
  # with self-exclusion + deposit-limit policy (manual fulfillment for now).
  def responsible_gaming
  end

  # Web3 onboarding guide: Phantom install → recovery phrase → $25 MoonPay
  # USDC purchase → first contest entry.
  def getting_started
  end
end
