module Admin
  # /admin/referrals — clicks to signups per trackable link. Read-only; the
  # numbers come from ReferralReport. `?days=7|30|all` picks the window and
  # `?reference=<name>` opens that reference's per-day table.
  class ReferralsController < ApplicationController
    before_action :require_admin

    def index
      @report = ReferralReport.new(window: params[:days])
      @reference = ReferralVisit.normalize_reference(params[:reference])
      @daily = @reference ? @report.daily(@reference) : []
    end
  end
end
