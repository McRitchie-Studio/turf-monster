module Games
  # FILLS `games.week` ON THE ROWS WRITTEN BEFORE EVERY WRITER SET IT.
  #
  # Measured 2026-10-24 on production: 165 of 288 NFL games carried
  # `week: NULL` (and no season_year / season_type either), every one of them
  # referenced by slate matchups that DO carry the week. `Game.where(week: 8)`
  # answered 0, so every reader that asks for a week by its slot saw nothing.
  #
  # SOURCES, in precedence order, for each NFL game whose week is null:
  #   1. its slate matchups' `week` — written by the odds-CSV ingest and the span
  #      slate builder. Used only when they agree on ONE week; a game whose
  #      matchups name two weeks is ambiguous and reported, never guessed.
  #   2. ESPN's own event, when the row carries an ESPN id (`external_id`):
  #      the summary's `header.week`.
  #   3. Neither: the row is left null and REPORTED by slug.
  #
  # The slot's other two columns (season_year, season_type) are filled only where
  # they are null, from the same source, so the game becomes reachable through
  # `Game.in_season_slot` and not just `where(week:)`. A column that already
  # holds a value is never overwritten.
  #
  # IDEMPOTENT: it only ever selects rows whose week is null, so a second run
  # finds nothing to do. DRY RUN unless `apply: true` — the dry run computes and
  # reports exactly what an apply would write, and writes nothing.
  class BackfillWeek
    Change = Data.define(:slug, :week, :season_year, :season_type, :source)
    Unresolved = Data.define(:slug, :reason)

    Result = Data.define(:apply, :candidates, :changes, :unresolved, :failed) do
      def by_week = changes.group_by(&:week).transform_values(&:size).sort.to_h
      def by_source = changes.group_by(&:source).transform_values(&:size)
    end

    def self.call(...) = new(...).call

    # `client` is the ESPN client (Nfl::Espn::Client), injectable for tests. It is
    # only asked about rows that carry an external_id and no matchup week.
    def initialize(apply: false, client: Nfl::Espn::Client.new)
      @apply = apply
      @client = client
    end

    def call
      games = Game.nfl.where(week: nil).order(:kickoff_at, :slug).to_a
      matchup_slots = matchup_slots_for(games)

      changes = []
      unresolved = []
      failed = []

      games.each do |game|
        change, reason = resolve(game, matchup_slots[game.slug])
        if change.nil?
          unresolved << Unresolved.new(slug: game.slug, reason: reason)
          next
        end

        if @apply
          error = write(game, change)
          if error
            failed << Unresolved.new(slug: game.slug, reason: error)
            next
          end
        end
        changes << change
      end

      Result.new(apply: @apply, candidates: games.size, changes: changes, unresolved: unresolved, failed: failed)
    end

    private

    # ONE query for every candidate's week-carrying matchups, slates included,
    # grouped by game slug.
    def matchup_slots_for(games)
      SlateMatchup.where(game_slug: games.map(&:slug)).where.not(week: nil)
                  .includes(:slate)
                  .group_by(&:game_slug)
    end

    def resolve(game, matchups)
      weeks = Array(matchups).map(&:week).uniq
      if weeks.size == 1
        slate = matchups.first.slate
        return [change_for(game, weeks.first, slate&.season_year&.to_i, slate&.season_type, "matchup"), nil]
      end
      return [nil, "matchups name #{weeks.size} weeks (#{weeks.sort.join(', ')})"] if weeks.size > 1

      return [nil, "no matchup week and no ESPN id"] if game.external_id.blank?

      espn_change(game)
    end

    def espn_change(game)
      header = @client.summary(event_id: game.external_id).to_h["header"].to_h
      week = header["week"]
      return [nil, "ESPN event #{game.external_id} carries no week"] if week.blank?

      season = header["season"].to_h
      [change_for(game, Integer(week), season["year"]&.to_i, season["type"]&.to_i, "espn"), nil]
    rescue Nfl::Espn::Client::Error, ArgumentError, TypeError => e
      [nil, "ESPN event #{game.external_id}: #{e.message}"]
    end

    def change_for(game, week, season_year, season_type, source)
      Change.new(
        slug: game.slug,
        week: week,
        season_year: game.season_year || season_year,
        season_type: game.season_type || season_type,
        source: source
      )
    end

    # update_columns, not save: a backfill restores a missing fact and must not
    # fire the score fan-out, broadcasts or `updated_at` churn a save carries.
    # The `week IS NULL` guard in the WHERE keeps a concurrent poller's write
    # authoritative. A unique-index collision (the per-slot focus_rank index) is
    # reported for that game, not raised over the rest of the run.
    def write(game, change)
      updated = Game.where(id: game.id, week: nil).update_all(
        week: change.week,
        season_year: change.season_year,
        season_type: change.season_type
      )
      updated.zero? ? "week was set by another writer during the run" : nil
    rescue ActiveRecord::RecordNotUnique => e
      "unique index refused the slot: #{e.message.lines.first&.strip}"
    end
  end
end
