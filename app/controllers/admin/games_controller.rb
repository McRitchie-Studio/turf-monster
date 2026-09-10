module Admin
  class GamesController < ApplicationController
    before_action :require_admin
    before_action :set_game

    # POST /admin/games/:slug/goals
    def record_goal
      goal = @game.goals.new(
        team_slug: params[:team_slug],
        player_slug: params[:player_slug].presence,
        minute: params[:minute].presence&.to_i
      )

      rescue_and_log(target: goal, parent: @game) do
        goal.save!
        render json: {
          success: true,
          goal: goal_json(goal),
          game: game_json(@game.reload)
        }
      end
    rescue StandardError => e
      render json: { success: false, error: e.message }, status: :unprocessable_entity
    end

    # DELETE /admin/games/:slug/goals/:id
    def remove_goal
      goal = @game.goals.find_by(id: params[:id])
      return render json: { success: false, error: "Goal not found" }, status: :not_found unless goal

      rescue_and_log(target: goal, parent: @game) do
        goal.destroy!
        render json: {
          success: true,
          game: game_json(@game.reload)
        }
      end
    rescue StandardError => e
      render json: { success: false, error: e.message }, status: :unprocessable_entity
    end

    # POST /admin/games/:slug/complete
    def complete_game
      rescue_and_log(target: @game) do
        # Game#conclude! owns the whole fan-out — status, matchup flip, contest
        # re-score, and BOTH live broadcasts. This used to be four lines here
        # that fired only the contest broadcast, so an admin concluding an NFL
        # game left the league scoreboard showing it as still playing.
        @game.conclude!
        render json: {
          success: true,
          game: game_json(@game.reload)
        }
      end
    rescue StandardError => e
      render json: { success: false, error: e.message }, status: :unprocessable_entity
    end

    private

    def set_game
      @game = Game.find_by(slug: params[:slug])
      return render json: { error: "Game not found" }, status: :not_found unless @game
    end

    def goal_json(goal)
      {
        id: goal.id,
        slug: goal.slug,
        teamSlug: goal.team_slug,
        playerSlug: goal.player_slug,
        playerName: goal.player&.name,
        teamEmoji: goal.team&.emoji,
        minute: goal.minute
      }
    end

    def game_json(game)
      {
        slug: game.slug,
        homeScore: game.home_score,
        awayScore: game.away_score,
        status: game.status,
        goals: game.goals.order(:created_at).map { |g| goal_json(g) }
      }
    end
  end
end
