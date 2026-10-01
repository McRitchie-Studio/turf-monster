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

      # What the settled-contest guard decided about ONE row: whether to skip it,
      # and the anomaly to report either way. A pair rather than a bare string,
      # so "report it" and "do not write it" can be answered independently —
      # conflating them is what made the guard veto a whole slot.
      Verdict = Data.define(:skip, :anomaly)

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

        verdicts = @allow_settled ? {} : settled_verdicts(rows)

        rows.each do |row|
          verdict = verdicts[row.external_id]
          @anomalies << verdict.anomaly if verdict
          next if verdict&.skip

          process(row)
        end

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
      # So the refusal is explicit, and it is here rather than in the scheduled
      # job, because the job is not the only caller — `bin/nfl-live-poll` is what
      # an operator reaches for when repairing a historical slot, which is
      # precisely when a settled contest is most likely to be in range.
      #
      # `status` IS THE SEAM, NOT `onchain_settled`. A contest is settled in the
      # database the moment `grade!` finishes; the on-chain settle is attempted
      # after and can legitimately still be pending, so a contest routinely
      # reads `settled` with `onchain_settled` false. Keying on the on-chain flag
      # would let a cycle walk straight through a graded, paid-out contest.
      #
      # ── IT IS DECIDED PER GAME, FROM THE CONTEST POPULATION ────────────────
      #
      # This used to be ONE question per cycle, answered before `rows.each`, and
      # that was a reachable regression that re-created the original bug.
      # `Slate has_many :contests` and `contests.slate_id` is not unique, so one
      # slate carries several tiers. An admin grades tier A on Sunday evening;
      # tier B is still open with paid entries; Monday Night Football is on the
      # same slate. Every tick thereafter found A, refused, and wrote NOTHING —
      # so MNF was never scored for anyone, and the games kept null slot columns,
      # which is what the tripwire used to need to see the gap the veto had just
      # created. The fix blinded its own alarm to itself.
      #
      # THE RULE, once: a game is skipped only when EVERY contest that renders it
      # is settled. Three outcomes, and the middle one is the whole point:
      #
      #   no contest in range          -> process. Nobody's settlement.
      #   settled only                 -> SKIP, one anomaly naming the game.
      #   settled AND open             -> process, and REPORT it.
      #
      # The third case is not a loophole, it is a choice between two harms, and
      # it is forced: the two tiers SHARE their SlateMatchup rows, and one row
      # cannot be both frozen for A and current for B. Refusing costs tier B the
      # original incident — a live paid contest scoring short forever. Proceeding
      # costs tier A's pick-detail view a correction toward the truth, while what
      # its money stands on does NOT move: `Game#score_affected_contests!` scopes
      # to `status: [:open]`, so a settled contest's stored `entries.score` and
      # `selections.points` are never recomputed. Scoring the live contest is
      # strictly the smaller harm, and the anomaly makes the trade visible.
      #
      # `open` is the same vocabulary `score_affected_contests!` uses on purpose:
      # the poller writes to OPEN contests, so it refuses exactly when there is a
      # settled contest to protect and no open contest to serve. A `pending` tier
      # is not scored either, so it cannot unblock a settled one.
      #
      # THE LONGER FUSE IS LARGELY DEFUSED BY THIS SHAPE. `Game#name_slug` for a
      # regular-season game is bare "<home>-vs-<away>" with no year or week, so a
      # 2026 settled contest's matchup slug is matched by a 2027 scoreboard row.
      # Under the per-cycle veto that poisoned the whole slot. Now it can only
      # skip a game on a slate with NO open contest — i.e. one nobody is playing,
      # where there is nothing to score. The bare slug is pre-existing and is
      # left alone deliberately: narrowing it is a slug migration across
      # SlateMatchup, Selection and every settled contest's stored rows.
      #
      # Returns `external_id => Verdict`, with the anomaly already built, so the
      # loop in `call` stays a loop.
      def settled_verdicts(rows)
        rows.each_with_object({}) do |row, verdicts|
          # Resolved ONCE per row and handed to every lookup below. They used to
          # be looked up up to four times per row, every five minutes, through an
          # uncached `Team.nfl.find_by` — see #team_for.
          home = team_for(row.home_abbr)
          away = team_for(row.away_abbr)

          slate_ids = slate_ids_for(row, home: home, away: away)
          next if slate_ids.empty?

          contests = Contest.where(slate_id: slate_ids)
          # `.order(:slug)` because `pick` is otherwise unordered, and an anomaly
          # naming a different contest on each tick is one an operator cannot grep.
          settled = contests.settled.order(:slug).pick(:slug)
          next if settled.nil?

          label = GameLookup.slug_for(row, home: home, away: away) || row.external_id
          verdicts[row.external_id] =
            if contests.open.exists?
              coscored(label, settled)
            else
              refusal(label, settled)
            end
        end
      end

      # Which slates this row's game is rendered on — BOTH HANDLES, unioned.
      #
      # The Game row we already hold is the blast radius this cycle will actually
      # rewrite; the slug the row WOULD take is what a SlateMatchup references,
      # and a matchup can name a slug before any Game row exists for it. Asking
      # only the first question would walk past a settled contest whose matchup
      # we hold and whose game we do not.
      def slate_ids_for(row, home:, away:)
        slugs = [
          GameLookup.find(row, home: home, away: away)&.slug,
          GameLookup.slug_for(row, home: home, away: away)
        ].compact.uniq
        return [] if slugs.empty?

        SlateMatchup.where(game_slug: slugs).pluck(:slate_id).uniq
      end

      # THE GAME IS WRITTEN, AND THE TRADE IS REPORTED. Reported as an anomaly
      # rather than raised: the CLI already prints anomalies and already treats
      # them as non-fatal, so it lands in the watch log where an operator is
      # looking. Not deduplicated across cycles for the same reason the refusal
      # never was — a settled contest's matchups moving is worth saying twice.
      def coscored(label, contest_slug)
        Verdict.new(skip: false, anomaly: Anomaly.new(
          kind: "settled_contest_coscored",
          detail: "#{label}: scored for an OPEN contest on this slate, which settled contest " \
                  "#{contest_slug} shares — so its matchup goals moved too. Its own entry " \
                  "scores, ranks and payouts were NOT recomputed; refusing instead would leave " \
                  "the open contest scoring short forever."
        ))
      end

      # NOTHING IS WRITTEN FOR THIS GAME. `games_seen` stays the honest count —
      # the scoreboard WAS read — and the other games on the slot are unaffected.
      def refusal(label, contest_slug)
        Verdict.new(skip: true, anomaly: Anomaly.new(
          kind: "settled_contest",
          detail: "#{label}: every contest on this game's slate is settled (#{contest_slug}) — " \
                  "refusing to rewrite a graded contest's matchups. Its ranks and payouts are " \
                  "final, and `Contest#grade!` cannot repair a disagreement: it raises on a " \
                  "settled contest by design. Override deliberately with " \
                  "bin/nfl-live-poll --allow-settled."
        ))
      end

      # MEMOIZED FOR THE CYCLE. `Espn::TeamMap.team_for` is an uncached
      # `Team.nfl.find_by`, and a 16-game slate asks for the same 32
      # abbreviations from the settled check, the upsert, the possession write and
      # every scoring play — every five minutes, forever. `key?` rather than `||=`
      # so a genuinely unmapped abbreviation is remembered as nil instead of
      # re-queried on each ask.
      def team_for(abbreviation)
        @team_cache ||= {}
        key = abbreviation.to_s
        return @team_cache[key] if @team_cache.key?(key)

        @team_cache[key] = Espn::TeamMap.team_for(key)
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
        home = team_for(row.home_abbr)
        away = team_for(row.away_abbr)

        unless home && away
          missing = [row.home_abbr, row.away_abbr].reject { |a| team_for(a) }
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

        team_for(row.possession_abbr)&.slug
      end

      # Lookup order matters and is shared by `process`, `upsert_game` and
      # `settled_contest_slug`. It lives in `GameLookup` because
      # `SilentGapCheck` asks the same question from outside this class, and a
      # copy that lost the slug fallback would silently answer "no such game"
      # about exactly the rows the 2026 week-2 incident was made of.
      def find_game(row) = GameLookup.find(row, home: team_for(row.home_abbr), away: team_for(row.away_abbr))

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
        team = team_for(play.team_abbr)
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
