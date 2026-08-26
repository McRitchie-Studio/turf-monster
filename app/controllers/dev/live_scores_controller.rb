module Dev
  # Score injectors for the /live scoreboard, so the real-time UX can be
  # exercised without waiting for an actual NFL game to be played.
  #
  # These write REAL Goal rows. That is the entire point: a button that only
  # fired a broadcast would show the toast animation while proving nothing
  # about the thing it exists to prove — that a scoring event recomputes the
  # game score, propagates to every SlateMatchup, re-scores every open contest,
  # and reaches every connected browser. Injecting at the top of that pipeline
  # exercises all of it.
  #
  # The routes are undrawn in production (see routes.rb) AND the environment is
  # re-checked here, because a dev-only write path guarded in exactly one place
  # is a dev-only write path guarded in zero places the day someone reorganises
  # the routes file.
  class LiveScoresController < ApplicationController
    # Same posture as the other dev-only controllers (ToastTestController,
    # SeedsLabController): the environment gate IS the access control, and the
    # routes are not drawn in production either way.
    skip_before_action :require_authentication

    before_action :require_non_production
    before_action :set_game

    # POST /dev/live_scores/record
    def record
      team = Team.nfl.find_by(slug: params[:team_slug])
      return render_error("Unknown team: #{params[:team_slug]}") unless team

      scoring_type = params[:scoring_type].to_s
      unless Goal::SCORING_TYPES.include?(scoring_type)
        return render_error("Unknown scoring type: #{scoring_type}")
      end

      # No external_id: these are ours, not the feed's. That keeps them out of
      # the poller's reconciliation entirely — it only ever reconciles rows
      # carrying an ESPN play id — so an injected touchdown is never mistaken
      # for a withdrawn one and deleted out from under the demo.
      goal = @game.goals.create!(
        team_slug: team.slug,
        points: Goal.points_for(scoring_type),
        scoring_type: scoring_type
      )

      render json: {
        success: true,
        goal: { slug: goal.slug, points: goal.points, scoring_type: goal.scoring_type },
        game: game_json(@game.reload)
      }
    rescue StandardError => e
      render_error(e.message)
    end

    # POST /dev/live_scores/clear_game — back to kickoff.
    #
    # delete_all, not destroy_all: clearing ten goals one at a time would fire
    # ten score recomputations and ten broadcasts, so every viewer would watch
    # the score count backwards. One bulk delete then one explicit recompute
    # and one broadcast is both faster and what a reset should look like.
    def clear_game
      @game.goals.delete_all
      @game.update!(status: "scheduled", period: nil, clock: nil, status_detail: nil)
      @game.update_scores_from_goals!

      Contest::LiveBroadcast.score_changed(@game, event: :goal_removed)
      Nfl::LiveBroadcast.score_changed(@game)

      render json: { success: true, game: game_json(@game.reload) }
    rescue StandardError => e
      render_error(e.message)
    end

    private

    def require_non_production
      return unless Rails.env.production?

      render json: { success: false, error: "Not available" }, status: :forbidden
    end

    def set_game
      @game = Game.find_by(slug: params[:game_slug])
      render_error("Unknown game: #{params[:game_slug]}", status: :not_found) unless @game
    end

    def render_error(message, status: :unprocessable_entity)
      render json: { success: false, error: message }, status: status
    end

    def game_json(game)
      {
        slug: game.slug,
        homeScore: game.home_score.to_i,
        awayScore: game.away_score.to_i,
        status: game.status
      }
    end
  end
end
