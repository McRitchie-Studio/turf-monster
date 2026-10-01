module Admin
  class DashboardController < ApplicationController
    before_action :require_admin

    def show
      @season_config = SeasonConfig.current
      @explicit_main = SeasonConfig.main_contest_explicit
      @resolved_main = SeasonConfig.main_contest
      # Open contests are the "main" candidates (locking is derived now, not a
      # status — an open-but-time-locked contest is still a valid pick).
      # Settled contests are excluded — pointing the share/root surfaces at a
      # finished contest would route new traffic to a dead end.
      @selectable_contests = Contest.where(status: [:open])
                                    .order(created_at: :desc)

      # Recently-active users for the dashboard's Users card. Load a page worth
      # (the view shows 5 and reveals the rest via "Show more"); the recently
      # active are the interesting ones, so order by last session.
      @recent_users = User.by_recent_session.with_attached_avatar.limit(25)

      # Recent outbound API calls (Stripe / Solana RPC / MoonPay) for the
      # Request Logs card — full browser + filters at /admin/outbound_requests.
      @recent_requests = OutboundRequest.recent.limit(12)
    end

    def update
      rescue_and_log(target: SeasonConfig.current) do
        # Blank string from the dropdown's "— none —" option clears the
        # pointer; otherwise we coerce to an integer ID before save.
        raw = params[:main_contest_id].to_s
        id  = raw.empty? ? nil : raw.to_i
        SeasonConfig.set_main_contest!(id)
        redirect_to admin_dashboard_path, notice: "Main contest updated."
      end
    rescue StandardError => e
      redirect_to admin_dashboard_path, alert: "Failed to update: #{e.message}"
    end
  end
end
