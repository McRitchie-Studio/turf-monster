module Nfl
  module LiveScores
    # ONE polling cycle: read the scoreboard, write whatever changed, report it.
    #
    # This object is the deterministic half of the live-scoring feature. It is
    # called on a fixed cadence by an agent that decides nothing — every rule
    # about what a scoring play is worth, which game it belongs to, and when a
    # contest re-scores lives here, in code, under test. The agent's job is to
    # call this and read out what it returns.
    #
    # It is also IDEMPOTENT, which is what makes that arrangement safe. Running
    # it twice in a row writes nothing the second time, because every scoring
    # event is keyed by ESPN's own play id under a unique index. A cycle that
    # dies halfway leaves no torn state, and a re-run picks up exactly where it
    # stopped — so an interrupted twelve-hour session resumes simply by being
    # started again.
    #
    # Cost per cycle: ONE scoreboard request covering every game, plus one
    # summary request per game whose score actually moved. Across a full Sunday
    # slate that second number averages under one.
    class PollCycle
      # A slot is one week of one season type — the unit ESPN's scoreboard
      # serves and the unit the /live page renders.
      Slot = Data.define(:year, :season_type, :week) do
        def to_h = { year: year, season_type: season_type, week: week }
      end

      # One thing that changed, in a shape that serialises straight to the
      # terminal. Deliberately plain strings and integers, not model objects:
      # the consumer is a CLI printing a line per change.
      Change = Data.define(
        :kind, :game, :team, :points, :scoring_type, :text,
        :home_team, :away_team, :home_score, :away_score, :detail, :contests
      ) do
        def to_h = super.compact
      end

      # Something we could not act on. Anomalies never stop the cycle — the
      # feed is not ours and will have bad minutes — but they are always
      # reported, because a silently skipped team is the failure mode that
      # settles a contest on a wrong score.
      Anomaly = Data.define(:kind, :detail)

      Result = Data.define(:slot, :games_seen, :changes, :anomalies) do
        def to_h
          {
            slot: slot&.to_h,
            games_seen: games_seen,
            changes: changes.map(&:to_h),
            anomalies: anomalies.map(&:to_h)
          }
        end

        def quiet? = changes.empty? && anomalies.empty?
      end

      def self.call(...) = new(...).call

      def initialize(slot: nil, client: Espn::Client.new)
        @slot = slot
        @client = client
        @changes = []
        @anomalies = []
      end

      def call
        payload = fetch_scoreboard
        rows = Espn::Scoreboard.rows_from(payload)

        rows.each { |row| process(row) }

        Result.new(
          slot: @slot || slot_from(rows),
          games_seen: rows.length,
          changes: @changes,
          anomalies: @anomalies
        )
      end

      private

      attr_reader :client

      # With no slot given, a bare scoreboard request returns whatever ESPN
      # considers current — which is the correct answer far more reliably than
      # anything we could compute from a calendar.
      def fetch_scoreboard
        if @slot
          client.scoreboard(year: @slot.year, season_type: @slot.season_type, week: @slot.week)
        else
          client.scoreboard
        end
      end

      def slot_from(rows)
        first = rows.first
        return nil unless first

        Slot.new(year: first.season_year, season_type: first.season_type, week: first.week)
      end

      def process(row)
        # Captured BEFORE the upsert, which is the whole point. `upsert_game`
        # writes the feed's status onto the row, so asking the saved game
        # whether it is complete always answers "yes" the moment ESPN says so —
        # and the finalisation below would never run even once. What decides it
        # is whether the game was ALREADY complete when this cycle started.
        was_completed = find_game(row)&.completed? || false

        game = upsert_game(row)
        return unless game

        # THE FEED HAS TO TELL US THE SCORE BEFORE WE ACT ON IT.
        # A blank score on a game ESPN says is live or final is a degraded
        # response, not a 0-0 — and acting on it is what let a wiped board look
        # like agreement. Reported, then skipped: the game keeps what it has.
        unless scores_known?(row)
          @anomalies << Anomaly.new(
            kind: "degraded_feed",
            detail: "#{row.external_id}: scoreboard carried no score for a #{row.status} game"
          )
          return
        end

        # A summary request is the expensive half of a cycle, so it is spent
        # only when the feed's score disagrees with ours. A live game whose
        # score has not moved needs no play detail.
        sync_scoring_plays(game, row) if score_disagrees?(game, row)

        # NEVER SETTLE A GAME WE CANNOT RECONCILE.
        #
        # Finalising flips every matchup to completed and re-scores every open
        # contest — it is the moment a number stops being provisional. Doing
        # that while our summed events disagree with the feed's total settles a
        # contest on a score one side of the system does not believe. The
        # disagreement is reported and the game stays open; the next clean cycle
        # finalises it.
        if row.status == "completed" && !was_completed
          if score_disagrees?(game.reload, row)
            @anomalies << Anomaly.new(
              kind: "unsettled_final",
              detail: "#{game.slug}: feed says FINAL at #{row.away_score}-#{row.home_score} " \
                      "but our events sum to #{game.away_score}-#{game.home_score} — not settling"
            )
            # STATUS AND SETTLEMENT MOVE TOGETHER, or they lie about each other.
            # `upsert_game` has already written the feed's "completed", so
            # leaving it there would show FINAL on the board while the matchups
            # sit open and no contest has scored — a settled-looking game that
            # is not settled. Held at in_progress instead; the next cycle that
            # reconciles will complete and settle it in one move.
            game.update!(status: "in_progress")
          else
            finalise(game, row)
          end
        end

        detect_drift(game, row)
      rescue Espn::Client::Error => e
        # One bad game must not cost us the other fifteen.
        @anomalies << Anomaly.new(kind: "fetch_failed", detail: "#{row.external_id}: #{e.message}")
      rescue StandardError => e
        # ANYTHING ELSE IS STILL NOT ALLOWED TO BE SILENT. Only provider errors
        # were rescued before, so a PG::UniqueViolation mid-reconcile aborted the
        # cycle with nothing written anywhere a human would look. House
        # discipline is that every workflow rescues into an ErrorLog.
        ErrorLog.capture!(e)
        @anomalies << Anomaly.new(kind: "cycle_error", detail: "#{row.external_id}: #{e.class}: #{e.message}")
      end

      # A scheduled game legitimately carries no score yet — that is 0-0 and not
      # worth reporting. A game the feed calls live or final MUST carry one.
      def scores_known?(row)
        return true if row.status == "scheduled"

        !row.home_score.nil? && !row.away_score.nil?
      end

      # Lookup order matters. `external_id` first, because it is collision-proof.
      # Then the computed slug, so a game the odds CSV already created is
      # ADOPTED and stamped rather than duplicated — without that step the
      # poller would build a parallel set of games that no contest points at,
      # and scores would update nothing.
      def upsert_game(row)
        home = Espn::TeamMap.team_for(row.home_abbr)
        away = Espn::TeamMap.team_for(row.away_abbr)

        unless home && away
          missing = [row.home_abbr, row.away_abbr].reject { |a| Espn::TeamMap.team_for(a) }
          @anomalies << Anomaly.new(kind: "unknown_team", detail: missing.join(", "))
          return nil
        end

        game = find_game(row) || Game.new

        game.assign_attributes(
          external_id: row.external_id,
          home_team_slug: home.slug, away_team_slug: away.slug,
          season_year: row.season_year, season_type: row.season_type, week: row.week,
          kickoff_at: row.kickoff_at, status: status_for(game, row),
          period: row.period, clock: row.clock, status_detail: row.detail
        )
        game.slug = slug_for(row, home, away) if game.slug.blank?
        game.save!
        game
      end

      # Lookup order matters and is shared by `process` and `upsert_game`:
      # `external_id` first because it is collision-proof, then the computed
      # slug so an odds-CSV game is adopted rather than duplicated.
      def find_game(row)
        by_id = Game.find_by(external_id: row.external_id)
        return by_id if by_id

        home = Espn::TeamMap.team_for(row.home_abbr)
        away = Espn::TeamMap.team_for(row.away_abbr)
        return nil unless home && away

        Game.find_by(slug: slug_for(row, home, away))
      end

      # GAME STATE ONLY MOVES FORWARD.
      #
      # A stale scoreboard row — a cached edge response, a retry that landed on
      # an older copy — reports an earlier state. Letting it win re-opens a
      # settled game AND re-arms `finalise`, which re-runs the matchup flip and
      # re-broadcasts FINAL to everyone watching. Measured: a third cycle
      # re-emitted a "final" change for a game that had already ended.
      def status_for(game, row)
        return row.status unless game.persisted? && game.completed?
        return row.status if row.status == "completed"

        @anomalies << Anomaly.new(
          kind: "status_regression",
          detail: "#{game.slug}: feed says #{row.status} for a game already completed — keeping completed"
        )
        game.status
      end

      def slug_for(row, home, away)
        Game.new(
          home_team_slug: home.slug, away_team_slug: away.slug,
          season_type: row.season_type, week: row.week
        ).name_slug
      end

      def score_disagrees?(game, row)
        return false unless scores_known?(row)

        game.home_score.to_i != row.home_score.to_i ||
          game.away_score.to_i != row.away_score.to_i
      end

      # Reconcile our scoring events against the feed's, in both directions.
      # The destroy half is not defensive padding: ESPN really does withdraw
      # plays when a touchdown is overturned on review, and a Goal that
      # outlives its play would leave a contest scored on points nobody scored.
      def sync_scoring_plays(game, row)
        payload = client.summary(event_id: row.external_id)

        # THE FEED DECLINED TO ANSWER. An absent scoringPlays key is not an
        # empty game — it is a degraded 200 — and reconciling against it deletes
        # every goal the game holds.
        unless Espn::ScoringPlays.reported?(payload)
          @anomalies << Anomaly.new(
            kind: "degraded_feed",
            detail: "#{game.slug}: summary carried no scoringPlays list"
          )
          return
        end

        plays = Espn::ScoringPlays.rows_from(
          payload, home_abbr: row.home_abbr, away_abbr: row.away_abbr
        )

        existing = game.goals.where.not(external_id: nil).index_by(&:external_id)
        seen = plays.map(&:external_id).to_set

        # THE FLOOR: never reconcile DOWNWARD to nothing.
        #
        # A feed that reports zero plays for a game we hold scores on is
        # describing a state that cannot have happened — plays are not un-played
        # wholesale — so the likeliest explanation is a bad response, and the
        # cheap mistake is to believe it. Withdrawing plays ONE at a time still
        # works below; it is only the clean sweep that is refused.
        if plays.empty? && existing.any?
          @anomalies << Anomaly.new(
            kind: "degraded_feed",
            detail: "#{game.slug}: feed reported 0 plays while we hold #{existing.size} — refusing to wipe"
          )
          return
        end

        plays.each do |play|
          next if existing.key?(play.external_id)

          record_play(game, row, play)
        end

        existing.each do |external_id, goal|
          next if seen.include?(external_id)

          goal.destroy!
          @changes << change_for(game.reload, "reversed", team: goal.team, points: -goal.points,
                                                          scoring_type: goal.scoring_type)
        end
      end

      def record_play(game, row, play)
        team = Espn::TeamMap.team_for(play.team_abbr)
        unless team
          @anomalies << Anomaly.new(kind: "unknown_team", detail: play.team_abbr.to_s)
          return
        end

        # create! fires Goal's callbacks, which recompute the game score,
        # propagate to every SlateMatchup, re-score every open contest, and
        # broadcast to both live pages. Nothing in this file has to do any of
        # that by hand — that pipeline already existed.
        game.goals.create!(
          team_slug: team.slug, points: play.points,
          scoring_type: play.scoring_type, external_id: play.external_id
        )

        @changes << change_for(game.reload, "score", team: team, points: play.points,
                                                     scoring_type: play.scoring_type, text: play.text,
                                                     detail: row.detail)
      end

      # Mirrors what the admin console's complete_game does, for the same
      # reason: marking a game final bypasses the Goal callbacks, so the
      # matchup flip and the FINAL broadcast have to be triggered explicitly.
      def finalise(game, row)
        game.conclude!(detail: row.detail)

        @changes << change_for(game.reload, "final", detail: row.detail)
      end

      # After reconciling, our score is the sum of our scoring events and the
      # feed's is its own. They should agree. When they do not, something was
      # skipped — and saying so is far better than serving a confidently wrong
      # scoreboard.
      def detect_drift(game, row)
        return unless scores_known?(row)
        return unless score_disagrees?(game.reload, row)

        @anomalies << Anomaly.new(
          kind: "score_drift",
          detail: "#{game.slug}: ours #{game.away_score}-#{game.home_score}, " \
                  "ESPN #{row.away_score}-#{row.home_score}"
        )
      end

      def change_for(game, kind, team: nil, points: nil, scoring_type: nil, text: nil, detail: nil)
        Change.new(
          kind: kind, game: game.slug,
          team: team&.short_name, points: points, scoring_type: scoring_type, text: text,
          home_team: game.home_team&.short_name, away_team: game.away_team&.short_name,
          home_score: game.home_score.to_i, away_score: game.away_score.to_i,
          detail: detail || game.status_detail, contests: affected_contest_count(game)
        )
      end

      def affected_contest_count(game)
        slate_ids = SlateMatchup.where(game_slug: game.slug).pluck(:slate_id).uniq
        return 0 if slate_ids.empty?

        Contest.where(slate_id: slate_ids, status: [:open]).count
      end
    end
  end
end
