module Admin
  class SlatesController < ApplicationController
    before_action :require_admin

    # GET /admin/slates/:slug/manage
    def manage
      @slate = Slate.find_by(slug: params[:slug])
      return redirect_to contests_path, alert: "Slate not found" unless @slate

      @games = Game.where(
        slug: @slate.slate_matchups.pluck(:game_slug).uniq
      ).includes(:home_team, :away_team, :goals).order(:kickoff_at)
    end
  end
end
