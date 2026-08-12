class PagesController < ApplicationController
  skip_before_action :require_authentication

  def turf_totals_v1
  end

  def terms
    # The Terms' state-eligibility section renders the LIVE enforcement list
    # (same source as /state-eligibility) so policy can't drift from the gate.
    @excluded_states = GeoSetting.effective_banned_states
  end

  def privacy
  end

  def about
  end

  def contact
  end

  # Underwriting compliance: published state-eligibility policy, rendered
  # from GeoSetting (the IP-geolocation enforcement source of truth).
  def state_eligibility
    @excluded_states = GeoSetting.effective_banned_states
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
