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
