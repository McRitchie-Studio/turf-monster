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

      # WHAT AN AMENDMENT WAS WORTH, named by the delta rather than by the play it
      # rides on. ESPN restates a touchdown when the try lands, so the point that
      # arrives is the extra point: reporting it as "+1 touchdown" would name the
      # wrong half of the play. Two is the conversion and never a safety —
      # whatever a standalone 2 means elsewhere, these points went to the team
      # that already had the ball. Any other delta keeps the play's own type.
      AMENDMENT_TYPES = { 1 => "pat", 2 => "two_point" }.freeze

      def self.call(...) = new(...).call

      # `allow_settled` is the deliberate override for the one case the guard
      # below refuses. It is false everywhere except an operator who has read
      # the seam and decided anyway — never on a schedule.
      def initialize(slot: nil, client: Espn::Client.new, allow_settled: false)
        @slot = slot
        @client = client
        @allow_settled = allow_settled
        @changes = []
        @anomalies = []
      end

      def call
        payload = fetch_scoreboard
        rows = Espn::Scoreboard.rows_from(payload)
        slot = @slot || slot_from(rows)

        settled = settled_contest_slug(rows) unless @allow_settled
        return refuse_settled(slot, rows, settled) if settled

        rows.each { |row| process(row) }

        Result.new(
          slot: slot,
          games_seen: rows.length,
          changes: @changes,
          anomalies: @anomalies
        )
      end

      private

      # GRADING AND SETTLEMENT ARE SEPARATE ACTS, AND THIS IS THE SEAM.
      #
      # A cycle is idempotent about SCORING EVENTS — every play is keyed on
      # ESPN's own id under a unique partial index, so running it twice writes
      # nothing the second time. It is NOT idempotent about consequences: a
      # single new or withdrawn play re-sums the game, rewrites every
      # SlateMatchup#goals the game feeds, and re-scores every OPEN contest on
      # those slates.
      #
      # `Game#score_affected_contests!` already scopes to open contests, so a
      # settled contest is not re-scored — but that is the wrong place to rely
      # on, because the MATCHUP rows are rewritten regardless and they are what
      # a settled contest's standings render from. A cycle that moves a matchup
      # under a contest whose ranks and payouts are already final produces a
      # leaderboard that disagrees with the money that was paid out, and
      # `Contest#grade!` cannot fix it: it raises on a settled contest by design.
      #
      # So the refusal is explicit, and it is here rather than in the scheduled
      # job, because the job is not the only caller — `bin/nfl-live-poll` is what
      # an operator reaches for when repairing a historical slot, which is
      # precisely when a settled contest is most likely to be in range.
      #
      # IT IS DECIDED BEFORE ANY WRITE. The slot's games are the ones this cycle
      # is about to touch, resolved through the same lookup order `process` uses,
      # so the answer describes the real blast radius rather than a slot query
      # that might miss an adopted row.
      #
      # `status` IS THE SEAM, NOT `onchain_settled`. A contest is settled in the
      # database the moment `grade!` finishes; the on-chain settle is attempted
      # after and can legitimately still be pending, so a contest routinely
      # reads `settled` with `onchain_settled` false. Keying on the on-chain flag
      # would let a cycle walk straight through a graded, paid-out contest.
      def settled_contest_slug(rows)
        # BOTH HANDLES, unioned. The Game row we already hold is the blast radius
        # this cycle will actually rewrite; the slug the row WOULD take is what a
        # SlateMatchup references, and a matchup can name a slug before any Game
        # row exists for it. Asking only the first question would walk past a
        # settled contest whose matchup we hold and whose game we do not.
        slugs = rows.flat_map { |row| [GameLookup.find(row)&.slug, GameLookup.slug_for(row)] }.compact.uniq
        return nil if slugs.empty?

        slate_ids = SlateMatchup.where(game_slug: slugs).pluck(:slate_id).uniq
        return nil if slate_ids.empty?

        Contest.where(slate_id: slate_ids).settled.pick(:slug)
      end

      # Reported as an anomaly, not raised: the CLI already prints anomalies and
      # already treats them as non-fatal, so a refusal shows up in the watch log
      # exactly where an operator is looking. `games_seen` is still the honest
      # count — the scoreboard WAS read; nothing was written.
      def refuse_settled(slot, rows, contest_slug)
        Result.new(
          slot: slot,
          games_seen: rows.length,
          changes: [],
          anomalies: [Anomaly.new(
            kind: "settled_contest",
            detail: "contest #{contest_slug} on this slot is already SETTLED — refusing to " \
                    "re-score a graded contest. Its ranks and payouts are final; rewriting its " \
                    "matchups would leave the standings disagreeing with the money paid out."
          )]
        )
      end

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
          period: row.period, clock: row.clock, status_detail: row.detail,
          # THE SITUATION IS WRITTEN THROUGH EVEN WHEN IT IS NIL, and that is
          # the point of assigning it here rather than behind an `if`. ESPN
          # drops the block the moment a game ends, so a conditional write
          # would leave the last snap of the fourth quarter — "4th & Goal",
          # "NE 3" — frozen on a card that has said FINAL for an hour.
          down_distance: row.down_distance,
          possession_text: row.possession_text,
          possession_team_slug: possession_slug_for(row)
        )
        game.slug = slug_for(row, home, away) if game.slug.blank?
        game.save!
        game
      end

      # ESPN names the possessing team by abbreviation; the app names teams by
      # slug. Falls back to nil rather than to the raw abbreviation when the map
      # has no entry — an unmapped slug on the card would resolve to no team and
      # render an uncoloured, unnamed possession line, which says less than
      # showing no possession at all.
      def possession_slug_for(row)
        return nil if row.possession_abbr.blank?

        Espn::TeamMap.team_for(row.possession_abbr)&.slug
      end

      # Lookup order matters and is shared by `process`, `upsert_game` and
      # `settled_contest_slug`. It lives in `GameLookup` because
      # `SilentGapCheck` asks the same question from outside this class, and a
      # copy that lost the slug fallback would silently answer "no such game"
      # about exactly the rows the 2026 week-2 incident was made of.
      def find_game(row) = GameLookup.find(row)

      # GAME STATE ONLY MOVES FORWARD.
      #
      # A stale scoreboard row — a cached edge response, a retry that landed on
      # an older copy — reports an earlier state. Letting it win re-opens a
      # settled game AND re-arms `finalise`, which re-runs the matchup flip and
      # re-broadcasts FINAL to everyone watching. Measured: a third cycle
      # re-emitted a "final" change for a game that had already ended.
      def status_for(game, row)
        # A "completed" WE CANNOT RECONCILE IS NOT A STATUS WE CAN ACCEPT.
        # `process`'s `scores_known?` guard skips a degraded row only AFTER this
        # write lands, and a stored "completed" latches `was_completed` forever
        # after, so `finalise` never fires: FINAL on the board, matchups open.
        return game.status if row.status == "completed" && !scores_known?(row)

        return row.status unless game.persisted? && game.completed?
        return row.status if row.status == "completed"

        @anomalies << Anomaly.new(
          kind: "status_regression",
          detail: "#{game.slug}: feed says #{row.status} for a game already completed — keeping completed"
        )
        game.status
      end

      # Both teams are already resolved by the one caller left, so they are
      # handed in rather than looked up a second time.
      def slug_for(row, home, away) = GameLookup.slug_for(row, home: home, away: away)

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
          goal = existing[play.external_id]

          if goal
            amend_play(game, row, play, goal)
          else
            record_play(game, row, play)
          end
        end

        existing.each do |external_id, goal|
          next if seen.include?(external_id)

          goal.destroy!
          @changes << change_for(game.reload, "reversed", team: goal.team, points: -goal.points,
                                                          scoring_type: goal.scoring_type)
        end
      end

      # ESPN AMENDS A PLAY IT HAS ALREADY REPORTED, and the try is why.
      #
      # The extra point is not a play of its own — it is folded into the
      # touchdown that earned it, on the SAME play id, which reads 6 while the
      # kick is in the air and 7 once it is good. Reconciliation that only ever
      # CREATED therefore froze a touchdown caught mid-try at 6 for the rest of
      # the game, and `detect_drift` then reported the disagreement it had just
      # guaranteed, every cycle, forever.
      #
      # Measured on production during the 2026-08-27 preseason watch: four
      # touchdowns across two live games held 6 against a feed reading 7 — the
      # board showed CLE 26 to ESPN's 27, and every contest scored off it was a
      # point light.
      #
      # The amendment is reported as the DELTA, not the new total, so the watch
      # reads "+1 pat" — what actually just happened — rather than restating a
      # touchdown nobody scored twice.
      def amend_play(game, row, play, goal)
        delta = play.points - goal.points
        return if delta.zero? && goal.scoring_type == play.scoring_type

        goal.update!(points: play.points, scoring_type: play.scoring_type)

        # A play the feed merely RE-LABELS moved no points. Correct the row and
        # say nothing: a scoring line worth +0 is noise in a twelve-hour watch.
        return if delta.zero?

        @changes << change_for(game.reload, "score", team: goal.team, points: delta,
                                                     scoring_type: AMENDMENT_TYPES.fetch(delta, goal.scoring_type),
                                                     text: play.text, detail: row.detail)
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
        # `scorer_name` is what the feed said; `scorer_slug` is that name
        # resolved to a roster athlete, and is legitimately nil when we hold no
        # record for them. Resolved HERE, once, rather than on every render of a
        # row whose scorer never changes.
        game.goals.create!(
          team_slug: team.slug, points: play.points,
          scoring_type: play.scoring_type, external_id: play.external_id,
          scorer_name: play.scorer, scorer_slug: Goal.resolve_scorer_slug(play.scorer),
          play_description: play.description
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

        push_recap(game)
      end

      # Tell the studio hub a game finished, so it can open a content idea for
      # it. This is the LAST thing a finalisation does and by far the least
      # important one: the game is already settled and every contest has already
      # re-scored by the time we get here.
      #
      # So it can fail freely. A hub that is down, a Redis that will not take
      # the enqueue, a secret that was never set — none of those may cost a
      # contest its settlement, and none of them may end a twelve-hour watch.
      # Every failure becomes an anomaly, which the cycle already treats as
      # "reported, never fatal".
      #
      # It ENQUEUES rather than calling: an HTTP round trip to another host has
      # no business inside the loop that re-scores contests people paid to
      # enter. The worker dyno pays the network cost.
      def push_recap(game)
        return unless Studio::PushGameRecap.configured?

        Studio::GameRecapPushJob.perform_later(game.slug)
      rescue StandardError => e
        @anomalies << Anomaly.new(
          kind: "recap_push_failed",
          detail: "#{game.slug}: #{e.class} — #{e.message}"
        )
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
