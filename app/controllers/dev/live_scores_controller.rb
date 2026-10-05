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
      scorer = pick_scorer(team, scoring_type)

      goal = @game.goals.create!(
        team_slug: team.slug,
        points: Goal.points_for(scoring_type),
        scoring_type: scoring_type,
        scorer_name: scorer&.person&.full_name,
        scorer_slug: scorer&.person_slug,
        play_description: synthetic_description(scorer, scoring_type)
      )

      render json: {
        success: true,
        goal: { slug: goal.slug, points: goal.points, scoring_type: goal.scoring_type },
        game: game_json(@game.reload)
      }
    rescue StandardError => e
      render_error(e.message)
    end

    # POST /dev/live_scores/conclude_game
    #
    # Goes through Game#conclude!, the SAME path the ESPN poller takes when the
    # feed reports FINAL — so what this button reveals is the real final
    # broadcast, not a mock of one.
    # POST /dev/live_scores/record_play
    #
    # One line of play-by-play, the way the poller would have stored it: a
    # GamePlay row, then the same broadcast a polling cycle sends. `kind` is one
    # of GamePlay::KINDS; a "timeout" also spends one of the team's three, so
    # the pips on the feed can be watched counting down.
    #
    # It puts the game IN PROGRESS, because that is the only state in which a
    # play can arrive and the only one in which the feed shows timeouts. `Clear`
    # puts it back.
    def record_play
      # "first_down" is the toolbar's word for an ordinary snap that moved the
      # chains — the one kind of play the focus card's rail lists.
      first_down = params[:kind] == "first_down"
      kind = first_down ? "play" : (params[:kind].presence || "play")
      return render_error("Unknown play kind: #{kind}") unless GamePlay::KINDS.include?(kind)

      team = [@game.home_team, @game.away_team].compact.find { |side| side.slug == params[:team_slug] }
      sequence = @game.plays.maximum(:sequence).to_i + 1

      script = play_script(kind, team, sequence)
      @game.update!(live_attributes_after(kind, team).merge(possession_after(kind, team)))
      play = @game.plays.create!(
        external_id: "dev-#{@game.id}-#{sequence}", sequence: sequence, kind: kind,
        play_type: script[:type], yards: script[:yards], team_slug: team&.slug, period: @game.period, clock: @game.clock,
        first_down: first_down,
        down_distance: (kind == "play" ? "#{%w[1st 2nd 3rd].sample} & #{rand(1..10)} at #{team&.short_name} #{rand(20..45)}" : nil),
        text: params[:text].presence || script[:text]
      )

      Contest::LiveBroadcast.plays_changed(@game)

      render json: { success: true, play: { external_id: play.external_id, kind: play.kind, text: play.text },
                     game: game_json(@game.reload) }
    rescue StandardError => e
      render_error(e.message)
    end

    def conclude_game
      @game.conclude!

      render json: { success: true, game: game_json(@game.reload) }
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
      @game.plays.delete_all
      @game.update!(status: "scheduled", period: nil, clock: nil, status_detail: nil,
                    home_timeouts: nil, away_timeouts: nil)
      @game.update_scores_from_goals!

      Contest::LiveBroadcast.score_changed(@game, event: :goal_removed)
      Nfl::LiveBroadcast.score_changed(@game)

      render json: { success: true, game: game_json(@game.reload) }
    rescue StandardError => e
      render_error(e.message)
    end

    private

    # A PLAUSIBLE SCORER, so the injected play exercises the real card rather
    # than a blank one. The live feed names the scorer in its play text; there
    # is no text here, so we choose from the team's actual roster by position —
    # a kicker kicks the field goals, a skill player scores the touchdowns.
    #
    # `scorer_slug` pins a specific player, which is what the browser spec uses
    # to assert on a known name instead of whoever the roster happened to offer.
    # Returns nil freely: a desk seeded without athletes still records the goal,
    # and the card simply does not reveal.
    # The game as it stands after this play: live, with a clock, and — for a
    # team's own timeout — one fewer of its three.
    def live_attributes_after(kind, team)
      attributes = {
        status: "in_progress",
        period: @game.period || 1,
        clock: @game.clock.presence || "15:00",
        home_timeouts: @game.home_timeouts || 3,
        away_timeouts: @game.away_timeouts || 3
      }
      if kind == "timeout" && team
        column = team.slug == @game.home_team_slug ? :home_timeouts : :away_timeouts
        attributes[column] = [attributes[column] - 1, 0].max
      end
      attributes
    end

    # WHO HAS THE BALL after this play, and where — so the rail has a down to
    # print and a turnover has somebody to hand the ball to. The selected team
    # is the OFFENCE: a snap keeps it there; a turnover gives the ball to the
    # other side. Anything else (a timeout, a flag) leaves the ball where it is.
    def possession_after(kind, team)
      return {} unless team && %w[play turnover].include?(kind)

      holder = kind == "turnover" ? ([@game.home_team, @game.away_team].compact - [team]).first : team
      return {} unless holder

      spot = "#{holder.short_name} #{rand(20..45)}"
      { possession_team_slug: holder.slug, possession_text: spot,
        down_distance: "#{kind == "turnover" ? "1st" : %w[1st 2nd 3rd].sample} & 10 at #{spot}" }
    end

    # ONE PLAY, WRITTEN THE WAY ESPN WRITES IT — its type, its yardage, and
    # a line of text with players in it — so the board's summary (result,
    # detail, portraits) has the same things to read that a real play gives it.
    # Players come off the team's own roster when the dev database holds one,
    # so a seeded headshot can appear; otherwise stand-in names.
    def play_script(kind, team, sequence)
      name = team&.short_name || "Offense"
      other = ([@game.home_team, @game.away_team].compact - [team]).first
      qb = roster_name(team, %w[QB], "Q.Passer")
      wr = roster_name(team, %w[WR TE], "W.Catcher")
      rb = roster_name(team, %w[RB], "R.Runner")
      db = roster_name(other, %w[CB S DB LB], "D.Hawk")
      yards = rand(3..28)

      case kind
      when "timeout"  then { type: "Timeout", text: "Timeout ##{sequence} by #{name}." }
      when "penalty"  then { type: "Penalty", text: "PENALTY on #{name}-#{rb}, False Start, 5 yards, enforced at #{name} 30 - No Play." }
      when "break"    then { type: "Two-minute warning", text: "Two-Minute Warning" }
      when "turnover" then { type: "Pass Interception Return",
                             text: "(Shotgun) #{qb} pass short middle intended for #{wr} INTERCEPTED by #{db} at #{other&.short_name} 30. #{db} to #{other&.short_name} 35 for 5 yards.", yards: 5 }
      when "sack"     then { type: "Sack", yards: -7, text: "(Shotgun) #{qb} sacked at #{name} 23 for -7 yards (#{db})." }
      when "kick"     then { type: "Punt", text: "#{rb} punts 44 yards to #{other&.short_name} 20, fair catch." }
      when "score"    then { type: "Rushing Touchdown", yards: 12, text: "#{rb} left tackle for 12 yards, TOUCHDOWN." }
      else
        if sequence.odd?
          { type: "Pass Reception", yards: yards, text: "(Shotgun) #{qb} pass short right to #{wr} to #{other&.short_name} 30 for #{yards} yards (#{db})." }
        else
          { type: "Rush", yards: yards - 5, text: "#{rb} up the middle to #{name} 40 for #{yards - 5} yards (#{db})." }
        end
      end
    end

    # "J.Goff" for a rostered player at one of these positions, else the
    # stand-in. Deterministic (first by id), so a demo names the same passer
    # from one play to the next.
    def roster_name(team, positions, fallback)
      athlete = team && Athlete.football.for_team(team.slug).where(position: positions).includes(:person).order(:id).first
      return fallback unless athlete

      "#{athlete.person.first_name[0]}.#{athlete.person.last_name}"
    end

    TOUCHDOWN_POSITIONS = %w[WR RB TE QB].freeze
    FIELD_GOAL_POSITIONS = %w[K].freeze

    # A PLAUSIBLE PLAY, for the same reason as a plausible scorer: the live feed
    # describes the play in its text and there is no text here, so the card would
    # otherwise show a blank third row and prove nothing about the layout it
    # exists to prove. Keyed off the scorer's position — a back runs it in, a
    # receiver catches it, a kicker kicks it from range.
    RUSHING = %w[RB QB FB].freeze
    RECEIVING = %w[WR TE].freeze

    def synthetic_description(scorer, scoring_type)
      return Nfl::Espn::PlayDescription.from("", scoring_type) if scorer.nil?

      case scoring_type
      when "field_goal" then "#{rand(22..54)} yard field goal"
      when "touchdown"
        if RECEIVING.include?(scorer.position) then "#{rand(3..48)} yard receiving TD"
        elsif RUSHING.include?(scorer.position) then "#{rand(1..29)} yard rushing TD"
        else "Defensive touchdown"
        end
      else
        Nfl::Espn::PlayDescription.from("", scoring_type)
      end
    end

    def pick_scorer(team, scoring_type)
      if params[:scorer_slug].present?
        return Athlete.find_by(person_slug: params[:scorer_slug])
      end

      positions =
        case scoring_type
        when "field_goal" then FIELD_GOAL_POSITIONS
        when "touchdown"  then TOUCHDOWN_POSITIONS
        else return nil
        end

      Athlete.football.for_team(team.slug)
             .where(position: positions)
             .includes(:person)
             .order(Arel.sql("RANDOM()"))
             .first
    end


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
