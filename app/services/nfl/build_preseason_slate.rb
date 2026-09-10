module Nfl
  # Builds a TESTING slate over a preseason week — a real ESPN feed with no
  # money on it, reusable every August.
  #
  # Why this exists. The live scoring pipeline's whole point is that a scoring
  # play reaches a contest standing, and preseason is the only time we can watch
  # that happen against a live feed without a real contest riding on it. Without
  # a slate, the poller writes Goals into games no contest points at, every
  # report line reads "(0 contests)", and the half of the pipeline that matters
  # goes unexercised while the board looks perfect.
  #
  # THE CHAIN THIS CLOSES:
  #   PollCycle writes a Goal
  #     -> Game#update_scores_from_goals!   sums points
  #     -> Game#update_slate_matchups!      sets SlateMatchup#goals   <- needs THIS
  #     -> Game#score_affected_contests!    finds contests on the slate
  #     -> Contest#score_entries! -> Entry#score! -> Selection#compute_points!
  #
  # So the matchups need a rank and a turf_score as well as a game: a matchup
  # with no turf_score scores every entry zero and the chain looks broken when
  # it is only unpriced.
  class BuildPreseasonSlate
    PRESEASON = 1

    class Error < StandardError; end

    Result = Data.define(:slate, :games, :matchups, :contest)

    def self.call(...) = new(...).call

    def initialize(year:, week:, with_contest: true)
      @year = Integer(year)
      @week = Integer(week)
      @with_contest = with_contest
    end

    def call
      games = Game.nfl.in_season_slot(year: @year, season_type: PRESEASON, week: @week).to_a
      if games.empty?
        raise Error, "no preseason games for #{@year} week #{@week} — run bin/nfl-live-poll --slot #{@year}:1:#{@week} first"
      end

      slate = ensure_slate!
      matchups = ensure_matchups!(slate, games)
      price!(slate, matchups)
      contest = @with_contest ? ensure_contest!(slate) : nil

      Result.new(slate: slate, games: games, matchups: matchups, contest: contest)
    end

    def slate_name = "NFL #{@year} Preseason Week #{@week}"

    private

    # `week` USED TO BE DELIBERATELY NIL, and that was the load-bearing line in
    # this file. The reasoning was right and is worth keeping in view:
    #
    #   `Nfl::BuildSpanSlate` selected its sources with
    #   `Slate.where(week:, year:, sport:)`, so a preseason slate carrying
    #   `week: 4` answered that query for a regular-season "Weeks 2-4" contest
    #   and dragged exhibition matchups into it — silently, because the row
    #   looked like any other week-4 slate.
    #
    # Nilling the week solved that by making the slate UNFINDABLE, which also
    # made it unusable: a preseason SPAN could never be built, because its own
    # source slates could not be selected either. The collision was real; the
    # remedy was a workaround.
    #
    # `season_type` is now a column (see AddSeasonTypeToSlates), and both
    # week-based lookups scope by it — BuildSpanSlate#source_slates and
    # Slate#consecutive_weeks. So the week can be what it actually is, and the
    # ambiguity is resolved where it belongs rather than by hiding one side of
    # it.
    def ensure_slate!
      slate = Slate.find_or_initialize_by(name: slate_name)
      slate.week = @week
      slate.starts_at ||= Time.current
      slate.save!
      slate
    end

    def ensure_matchups!(slate, games)
      games.flat_map do |game|
        [[game.home_team, game.away_team], [game.away_team, game.home_team]].filter_map do |team, opponent|
          next if team.nil? || opponent.nil?

          matchup = SlateMatchup.find_or_initialize_by(slate: slate, team_slug: team.slug)
          matchup.assign_attributes(
            opponent_team_slug: opponent.slug,
            game_slug: game.slug,
            week: nil,
            # Seed the CURRENT score rather than zero: the builder can run
            # mid-slate (or after a rehearsal) and a matchup that reset to 0
            # would make every entry's score jump backwards on the next poll.
            goals: score_for(game, team)
          )
          matchup.save!
          matchup
        end
      end
    end

    # Ranks by each team's CURRENT score, then prices with the app's own curve so
    # an entry scores exactly as it would on a regular-season slate — the point
    # is to exercise the real formula, not a stand-in.
    #
    # Preseason carries no betting market and no projections, so there is nothing
    # to rank on before kickoff: every matchup ties at zero and rank falls back to
    # team_slug order. Fine for a rehearsal — turf_score still spans the real
    # curve — but this is NOT the regular-season ranking, which ranks on expected
    # points. Nothing here consults `Nfl::PointsDistribution`.
    #
    # AND RE-RUNNING MID-SLATE RE-PRICES PICKS THAT ARE ALREADY MADE. By then the
    # scores have moved, so the sort order moves, and `Selection#compute_points!`
    # reads the STORED turf_score every time it computes
    # (app/models/selection.rb:35, :42) — the pick-time-to-settlement drift that
    # method's own comment was written to prevent. Harmless HERE only because this
    # contest is free and never goes on-chain. Do not copy this method onto a
    # slate that settles.
    def price!(slate, matchups)
      n = matchups.length
      return if n.zero?

      ordered = matchups.sort_by { |m| [-(m.goals || 0), m.team_slug] }
      ordered.each_with_index do |matchup, index|
        rank = index + 1
        matchup.update!(
          rank: rank,
          turf_score: SlateMatchup.turf_score_for(rank, n, sport: "nfl")
        )
      end
    end

    # A FREE contest. Preseason is a rehearsal surface and an entry fee would
    # make it a real one — the slate exists so nobody has money on the outcome.
    def ensure_contest!(slate)
      contest = Contest.find_or_initialize_by(slate: slate, name: "#{slate_name} — Test")
      return contest if contest.persisted?

      contest.assign_attributes(
        entry_fee_cents: 0,
        max_entries: 100,
        status: :open,
        contest_type: "standard",
        starts_at: slate.starts_at,
        user: Contest.column_names.include?("user_id") ? User.order(:id).first : nil
      )
      contest.skip_onchain_callback = true if contest.respond_to?(:skip_onchain_callback=)
      contest.save!
      contest
    end

    def score_for(game, team)
      return game.home_score.to_i if team.slug == game.home_team_slug

      game.away_score.to_i
    end
  end
end
