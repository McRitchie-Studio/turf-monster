require "csv"
require "open-uri"

# Seeds Person + Athlete from nflverse's master players.csv — the identity
# backbone for every NFL player, with cross-references to ESPN, PFF, Spotrac/
# OTC, PFR, Sleeper and NFL. Later importers (grades, salaries, depth charts)
# match on those IDs instead of on fragile names.
#
# Source: https://github.com/nflverse/nflverse-data/releases/download/players/players.csv
#
# Defaults filter to status=ACT AND last_season >= 2026, which is the current
# active league (2,896 players across all 32 teams as of the 2026 preseason).
# The master CSV carries ~25k rows going back decades; pass min_season: 0 to
# ingest everything, or status_filter: nil to skip the status filter.
#
# Headshot caching is on by default and REQUIRES AWS credentials — the
# constructor raises if AWS_ACCESS_KEY_ID is missing rather than silently
# seeding 2,800 players with no avatars. Pass upload_headshots: false (or
# SKIP_HEADSHOTS=1 on the rake task) to opt out in CI and tests.
#
# Usage:
#   Nflverse::SeedPlayers.new.call
#   Nflverse::SeedPlayers.new(min_season: 2026, upload_headshots: false).call
class Nflverse::SeedPlayers
  PLAYERS_URL = "https://github.com/nflverse/nflverse-data/releases/download/players/players.csv".freeze
  DEFAULT_MIN_SEASON = 2026
  HEADSHOT_WIDTHS = [100, 400].freeze

  # The FACET a refused namesake files itself under in /admin/error_logs. It is
  # never raised — a refusal is this importer's policy, not an escaped
  # exception — but `Admin::ErrorLogsHelper.error_class_from_inspect` reads the
  # class name out of the `inspect` column, so refusals need a real class name
  # to group under. Naming it here keeps that string from being invented at the
  # write site, where a typo would silently scatter the facet.
  NamesakeRefused = Class.new(StandardError)

  # Every cross-reference this importer treats as proof of identity. A row that
  # shares NONE of these with an existing athlete of the same name is a
  # different human, whatever the names say.
  IDENTITY_COLUMNS = %i[gsis_id pff_id otc_id espn_id pfr_id nflverse_id].freeze

  # The order a namesake's slug suffix is cut from — and, by construction, the
  # order `ordered` sorts on. ONE list, so the row that sorts first is the row
  # whose suffix is computed from the highest-priority identifier. Two lists
  # would be free to drift.
  DISAMBIGUATOR_PRIORITY = %i[gsis_id espn_id pff_id otc_id pfr_id nflverse_id].freeze

  # The CSV header each identity column arrives under. Only `nflverse_id`
  # differs from its column name — the feed ships it as `nfl_id`.
  IDENTITY_CSV_COLUMNS = {
    gsis_id: "gsis_id", espn_id: "espn_id", pff_id: "pff_id",
    otc_id: "otc_id", pfr_id: "pfr_id", nflverse_id: "nfl_id"
  }.freeze

  # nflverse uses standard NFL abbreviations with a few quirks: "LA" for the
  # Rams, "LAC" for the Chargers, "LV" for the Raiders, "WAS" for the
  # Commanders. Maps to the team slugs this app already uses.
  TEAM_ABBR_TO_SLUG = {
    "ARI" => "arizona-cardinals",    "ATL" => "atlanta-falcons",
    "BAL" => "baltimore-ravens",     "BUF" => "buffalo-bills",
    "CAR" => "carolina-panthers",    "CHI" => "chicago-bears",
    "CIN" => "cincinnati-bengals",   "CLE" => "cleveland-browns",
    "DAL" => "dallas-cowboys",       "DEN" => "denver-broncos",
    "DET" => "detroit-lions",        "GB"  => "green-bay-packers",
    "HOU" => "houston-texans",       "IND" => "indianapolis-colts",
    "JAX" => "jacksonville-jaguars", "KC"  => "kansas-city-chiefs",
    "LA"  => "los-angeles-rams",     "LAC" => "los-angeles-chargers",
    "LV"  => "las-vegas-raiders",    "MIA" => "miami-dolphins",
    "MIN" => "minnesota-vikings",    "NE"  => "new-england-patriots",
    "NO"  => "new-orleans-saints",   "NYG" => "new-york-giants",
    "NYJ" => "new-york-jets",        "PHI" => "philadelphia-eagles",
    "PIT" => "pittsburgh-steelers",  "SF"  => "san-francisco-49ers",
    "SEA" => "seattle-seahawks",     "TB"  => "tampa-bay-buccaneers",
    "TEN" => "tennessee-titans",     "WAS" => "washington-commanders"
  }.freeze

  # `namesake_collisions` is the REFUSAL LOG — one entry per human this importer
  # declined to write because it could not give them their own slug. Never empty
  # silently: `call` prints every entry unconditionally, because each one is a
  # player missing from a live contest, not a statistic.
  attr_reader :stats, :namesake_collisions

  def initialize(verbose: false, upload_headshots: true,
                 min_season: DEFAULT_MIN_SEASON, status_filter: "ACT",
                 source_url: PLAYERS_URL, csv_body: nil)
    @verbose = verbose
    @upload_headshots = upload_headshots
    if @upload_headshots && ENV["AWS_ACCESS_KEY_ID"].blank?
      raise "AWS_ACCESS_KEY_ID not set — headshot caching requires AWS credentials. " \
            "Pass upload_headshots: false (or SKIP_HEADSHOTS=1) to opt out."
    end
    @min_season = min_season.to_i
    @status_filter = status_filter.presence
    @source_url = source_url
    @csv_body = csv_body
    @stats = Hash.new(0)
    @namesake_collisions = []
  end

  def call
    rows = ordered(parse_csv)
    puts "  #{rows.size} rows; filter: status=#{@status_filter || "any"} last_season>=#{@min_season}"

    rows.each do |row|
      next @stats[:skipped_inactive] += 1 if @status_filter && row["status"] != @status_filter

      last_season = row["last_season"].to_i
      next @stats[:skipped_old] += 1 if last_season.positive? && last_season < @min_season

      ingest_row(row)
    end

    report_namesake_collisions
    puts "\nnflverse seed: #{@stats.inspect}"
    @stats
  end

  # A DETERMINISTIC ingest order, independent of how the feed happens to ship
  # the file.
  #
  # It matters only for namesakes, and only on a rebuild from empty — which is
  # exactly what a pre-season re-seed is. Of two players sharing a name, the
  # FIRST one ingested keeps the clean "justin-jefferson" slug and the second
  # gets the disambiguated one. Leave that to CSV order and a rebuild can hand
  # the clean slug to the other player.
  #
  # That is not cosmetic here: person_slug is the foreign key this whole schema
  # joins on — grades, stats, headshots, contest picks — so a feed reorder
  # silently reassigns one man's record to another man. Measured on two
  # blank-GSIS Jefferson rows, reversing them moved the clean slug from ESPN
  # 4262921 to 4430737.
  #
  # It sorts on the WHOLE identifier priority, not on gsis_id alone. GSIS first
  # keeps the established order, but GSIS is blank on BOTH rows of a real
  # namesake pair often enough to matter, and when it is, it discriminates
  # nothing — leaving the CSV index as the only tiebreak, which is precisely the
  # file-order dependency this method exists to remove.
  #
  # The index survives as the LAST tiebreak, for rows sharing every identifier
  # (or carrying none): Ruby's `sort_by` is not stable, so without it those rows
  # could shuffle between runs.
  def ordered(rows)
    rows.each_with_index
        .sort_by { |row, index| identity_sort_key(row) << index }
        .map(&:first)
  end

  # Public so tests can drive a single row without a CSV. Returns the Athlete,
  # or nil if the row was skipped or failed.
  def ingest_row(row)
    gsis_id = row["gsis_id"].to_s.strip.presence
    pff_id  = row["pff_id"].to_s.strip.presence&.to_i
    otc_id  = row["otc_id"].to_s.strip.presence
    espn_id = row["espn_id"].to_s.strip.presence
    pfr_id  = row["pfr_id"].to_s.strip.presence

    # ID-hierarchy lookup. Every cross-ref nflverse provides is unique to one
    # player, so if any matches an existing Athlete that IS the record —
    # regardless of what the name says. This is what prevents "Will Anderson
    # Jr." (carrying a pff_id) and "Will Anderson" (from a source that drops
    # the suffix) from living as two Person+Athlete pairs.
    nflverse_id = row["nfl_id"].to_s.strip.presence
    identifiers = { gsis_id:, pff_id:, otc_id:, espn_id:, pfr_id:, nflverse_id: }
    athlete = lookup_athlete_by_ids(**identifiers)
    person = athlete&.person

    if athlete.nil?
      first = (row["common_first_name"].to_s.strip.presence || row["first_name"].to_s.strip)
      last  = row["last_name"].to_s.strip
      if first.empty? || last.empty?
        @stats[:skipped_no_name] += 1
        return nil
      end

      person = Person.find_or_create_by_name!(first, last, athlete: true)
      @stats[:people_created] += 1 if person.previously_new_record?

      athlete = resolve_athlete!(person, first, last, identifiers)
      # resolve_athlete! now REFUSES a namesake it cannot slug and returns nil.
      # Without this guard the nil falls through to `athlete.update!` below and
      # raises NoMethodError out of the rescue's reach — turning a counted skip
      # back into the run-killing raise the refusal exists to avoid.
      return nil unless athlete
    end

    # DEFER TO THE MASTER ON A SYNCED ROW, rather than letting the write be
    # refused whole.
    #
    # build_attrs writes 16 columns and 11 of them are Athlete::STUDIO_MASTERED.
    # `update!` is ATOMIC, so on a synced athlete the guard refuses the call and
    # the five columns this importer genuinely owns — college_name, the three
    # draft fields, jersey_number — are discarded with it. That is the exact
    # "Drafted: Undrafted forever" symptom the guard was narrowed to fix, and
    # narrowing it alone did not fix it: measured at be34e40e, the write raised
    # and all five local columns stayed nil. Worse, the rescue below catches
    # RecordInvalid/RecordNotUnique — SIBLINGS of ReadOnlyRecord, not ancestors
    # — so `nfl:players_seed` died at that row instead of degrading.
    #
    # So drop what the master owns and write what we own. Master-owned columns
    # arrive through Studio::SyncAthletes; this importer is the local half.
    attrs = build_attrs(row, gsis_id)
    attrs = attrs.except(*Athlete::STUDIO_MASTERED.map(&:to_sym)) if athlete.synced_at.present?
    begin
      athlete.update!(attrs.compact)
      @stats[:athletes_updated] += 1
    # ReadOnlyRecord is listed because it is a SIBLING of the two below, not an
    # ancestor — rescuing RecordInvalid never caught it. The `except` above
    # should mean we never raise it; this is the belt to that braces, so a row
    # that races the sync degrades to a counted failure instead of killing the
    # whole seed.
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::ReadOnlyRecord => e
      @stats[:athletes_failed] += 1
      vputs "  [!] update fail #{person&.slug} (gsis=#{gsis_id}): #{e.message}"
      return nil
    end

    # ASK THE ATHLETE, NOT THIS WRITE: `attrs` is excepted of every mastered
    # column on a synced row, and headshot_url has no fallback. cache! is idempotent.
    cache_headshot(athlete) if @upload_headshots && athlete.espn_headshot_url.present?
    athlete
  end

  private

  def lookup_athlete_by_ids(gsis_id:, pff_id:, otc_id:, espn_id:, pfr_id:, nflverse_id: nil)
    return Athlete.find_by(gsis_id:)     if gsis_id && Athlete.exists?(gsis_id:)
    return Athlete.find_by(pff_id:)      if pff_id  && Athlete.exists?(pff_id:)
    return Athlete.find_by(otc_id:)      if otc_id  && Athlete.exists?(otc_id:)
    return Athlete.find_by(espn_id:)     if espn_id && Athlete.exists?(espn_id:)
    return Athlete.find_by(pfr_id:)      if pfr_id  && Athlete.exists?(pfr_id:)
    # nflverse_id is written by build_attrs and carries a UNIQUE index, so it
    # must be probed here too. Missing it meant a row whose nflverse_id already
    # belonged to another athlete fell through to the NAME path, where the
    # guard below then reads it as a namesake and mints a second Person for one
    # human — and `update!` raises on the unique index either way.
    return Athlete.find_by(nflverse_id:) if nflverse_id && Athlete.exists?(nflverse_id:)

    nil
  end

  # Attach this row to the right Athlete, given a Person matched BY NAME.
  #
  # Reaching here means no cross-reference ID matched, so the Person we just
  # found may not be this human at all — two active players can share a name.
  # Seven pairs do in the 2026 league, and the first version of this method took
  # `Athlete.find_by(person_slug:)` at face value and let the second of each
  # pair overwrite the first, silently losing seven players.
  #
  # The tell is whether the existing record shares ANY cross-reference with this
  # row — not gsis_id alone:
  #   - no athlete yet              -> create one
  #   - athlete with no identity ID -> an unidentified record for this name (the
  #                                    offline demo seed, or a hand-entered
  #                                    row); adopt it rather than making a twin
  #   - athlete sharing an ID       -> the same human; adopt
  #   - athlete sharing NONE        -> a DIFFERENT human who happens to share
  #                                    the name; give them their own Person,
  #                                    slugged with a disambiguator, so the two
  #                                    never collide
  #
  # READING gsis_id ALONE IS THE BUG THIS REPLACES. The old condition
  # — `existing.gsis_id.blank? || existing.gsis_id == gsis_id` — is TRUE for a
  # blank-GSIS namesake PAIR, and nflverse ships plenty: a player has no GSIS
  # until he appears in a game, so two undrafted rookies sharing a name both
  # arrive blank. Both men then merged onto one athlete row. Nothing raised —
  # the row counted as an update, the Person was untouched, so the page still
  # showed a plausible name. The sibling replica sync hit the identical failure
  # on production data, where `chris-smith` ended up holding another man's gsis
  # 00-0038661: a row the master holds nothing for, so no rebuild could restore
  # him. That is why this is guarded in BOTH writers rather than in the one that
  # happened to be caught.
  def resolve_athlete!(person, first, last, identifiers)
    existing = Athlete.find_by(person_slug: person.slug)

    return existing if existing && adoptable_name_match?(existing, identifiers)

    disambiguator = disambiguator_for(identifiers, first, last) if existing
    if existing && disambiguator.blank?
      refuse_namesake!(first, last, existing, identifiers, "no league ID to derive a slug from")
      return nil
    end

    # ONE TRANSACTION, because the two writes are one fact. A Person created
    # here whose Athlete then fails leaves an ID-less orphan — and the NEXT run
    # recomputes the same disambiguator and dies on the unique index, wedging
    # every row after it. `ingest_row`'s rescue wraps `update!` and cannot see
    # any of this, which is why the rescue below belongs to THIS method.
    athlete  = nil
    collided = false
    ActiveRecord::Base.transaction do
      if existing
        person = Person.create!(
          first_name: first, last_name: last, athlete: true,
          disambiguator: disambiguator
        )
        collided = true
      end

      athlete = Athlete.create!(person_slug: person.slug, sport: "football")
    end

    # COUNTED AFTER THE COMMIT, never inside it. The rescue below rolls the
    # DATABASE back; it cannot roll `@stats` back. An increment taken inside the
    # transaction therefore SURVIVES the rollback, and the run summary
    # over-reports on exactly the runs that refused a human — the runs an
    # operator most needs a true number from.
    #
    # `athletes_created` was the worse half: it sat one line ABOVE the `create!`
    # it claimed to count, so it over-counted on every failure of that write,
    # not merely on a late one. The `vputs` moves out for the same reason — it
    # announced a name collision whose Person the rollback then took away.
    if collided
      @stats[:people_created] += 1
      @stats[:name_collisions] += 1
      vputs "  [~] name collision: #{first} #{last} -> #{person.slug}"
    end
    @stats[:athletes_created] += 1

    # RETURNED EXPLICITLY. `ingest_row` calls `athlete.update!` on what this
    # returns, so the method's value is load-bearing — and once the counters
    # moved below the transaction, the transaction's own value stopped being
    # the last expression. Leaving it implicit returned the Integer from the
    # `+= 1` above, and `ingest_row` died on `undefined method 'synced_at' for
    # an instance of Integer` two lines later.
    athlete
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    # SKIP AND RECORD — the policy this importer chose, and the reason the raise
    # that used to live in `disambiguator_for` is gone rather than moved.
    #
    # `nfl:players_seed` is a BULK rake task over a ~25k-row file. A raise on one
    # malformed row drops every row after it, so the rebuild meant to REPAIR the
    # data truncates instead, and the operator gets a stack trace rather than the
    # list of players who are missing. Taking the raise out of `disambiguator_for`
    # and leaving its twin one call away in `Person.create!` would only have moved
    # it: a uniqueness failure on the computed slug kills the run just as dead,
    # and reaching it takes nothing more exotic than three namesakes whose IDs
    # end in the same four digits.
    #
    # `disambiguator_for` already widens past a taken slug, so this is the
    # backstop for what it cannot see — a racing writer, or a Person the name
    # lookup could not reach — not the primary defence.
    if existing
      refuse_namesake!(first, last, existing, identifiers, e.message)
    else
      @stats[:athletes_failed] += 1
      vputs "  [!] could not create #{first} #{last}: #{e.message}"
    end
    nil
  end

  # Name matching can adopt a genuinely unidentified seed record — that is the
  # whole point of the demo-seed path. Once an Athlete carries ANY
  # cross-reference, though, a row that shares none of them is another person,
  # even when GSIS is blank on both sides.
  def adoptable_name_match?(existing, identifiers)
    existing_ids = IDENTITY_COLUMNS.filter_map do |column|
      value = existing.public_send(column)
      [column, value] if value.present?
    end.to_h

    return true if existing_ids.empty?

    identifiers.any? do |column, incoming|
      incoming.present? && existing_ids[column].to_s == incoming.to_s
    end
  end

  # REFUSE AND RECORD, in the vocabulary the sibling writer already uses.
  #
  # `Studio::SyncAthletes#build_for` records `{ person_slug:, ours:, theirs: }`
  # for exactly this event, and both writers land in the same two tables — so an
  # operator reading this app's output should meet ONE shape, not two. The hub
  # importer only COUNTS these; a bare counter is nearly as silent as the merge
  # it replaces, and this app settles contests people paid to enter, so the
  # humans get named.
  def refuse_namesake!(first, last, existing, identifiers, reason)
    @stats[:namesake_collisions_skipped] += 1
    collision = {
      person_slug: existing.person_slug,
      name: "#{first} #{last}",
      ours: leading_identifier(existing),
      theirs: DISAMBIGUATOR_PRIORITY.filter_map { |column| identifiers[column].presence }.first,
      reason: reason
    }
    @namesake_collisions << collision
    record_refusal(collision, existing)
    vputs "  [!] refused namesake #{first} #{last}: #{reason}"
  end

  # THE DURABLE HALF of skip-and-record. `report_namesake_collisions` answers
  # "who did we refuse" only for whoever happened to be watching the run; a week
  # later the scrollback is gone and the question is unanswerable. ErrorLog is
  # the durable home this repo ALREADY has — `Admin::ErrorLogsController` browses
  # it — so recording here introduces no table and no new concept.
  #
  # NOT `rescue_and_log`. That helper is a CONTROLLER concern and it RE-RAISES
  # (studio-engine app/controllers/concerns/studio/error_handling.rb). Re-raising
  # here would drop every remaining row of a ~25k-row rebuild — precisely the
  # truncation the rescue in `resolve_athlete!` exists to prevent. A refused
  # namesake is this importer's POLICY, not an exception that escaped.
  #
  # `slug` is set because `Admin::ErrorLogsController#show` looks rows up BY
  # slug, so a row without one is written but unreachable in the only UI that
  # reads it. `inspect` is written in the `#<Class: message>` shape
  # `Admin::ErrorLogsHelper.error_class_from_inspect` parses, so these group
  # under their own facet instead of falling into "Unknown".
  def record_refusal(collision, existing)
    log = ErrorLog.create!(
      message: "nflverse seed refused namesake #{collision[:name]}: #{collision[:reason]}",
      inspect: "#<#{NamesakeRefused}: #{collision.to_json}>",
      target: existing,
      target_name: collision[:person_slug]
    )
    log.update_column(:slug, "error-log-#{log.id}")
    log
  rescue StandardError => e
    # A BOOKKEEPING ROW MUST NEVER KILL THE IMPORT IT ONLY DESCRIBES. This is
    # the one place where swallowing is right: the refusal is already counted,
    # already in `@namesake_collisions`, and already on its way to stdout.
    vputs "  [!] could not record refusal for #{collision[:name]}: #{e.class}: #{e.message}"
    nil
  end

  def leading_identifier(athlete)
    DISAMBIGUATOR_PRIORITY.filter_map { |column| athlete.public_send(column).presence }.first
  end

  # UNCONDITIONAL, not behind `verbose`. A refused namesake is a player who will
  # not appear in a contest — it is the one line of this run's output that has to
  # survive being ignored.
  def report_namesake_collisions
    return if @namesake_collisions.empty?

    puts "\n  [!] #{@namesake_collisions.size} namesake(s) REFUSED — resolve these by hand:"
    @namesake_collisions.each do |collision|
      puts "      #{collision[:name]}: #{collision[:person_slug]} already holds " \
           "#{collision[:ours].inspect}, incoming #{collision[:theirs].inspect} " \
           "(#{collision[:reason]})"
    end
  end

  # The ingest order, as a sort key: each identifier in DISAMBIGUATOR_PRIORITY
  # order, present-before-absent then by value. Derived from that ONE list, so
  # the row that sorts FIRST is the row whose highest-priority identifier sorts
  # first — the same chain the suffix is cut from, by construction rather than
  # by two lists happening to agree.
  #
  # The comparison is lexicographic, so "1000" sorts before "999". Arbitrary,
  # but TOTAL, which is all this needs: the order has to be a function of the
  # data and of nothing else.
  def identity_sort_key(row)
    DISAMBIGUATOR_PRIORITY.flat_map do |column|
      value = row[IDENTITY_CSV_COLUMNS.fetch(column)].to_s.strip
      [value.empty? ? 1 : 0, value]
    end
  end

  # A short, STABLE suffix, derived from the league ID rather than a counter —
  # a counter would make a person's public URL depend on CSV ordering.
  #
  # Four digits reads well and separates almost every pair, but "almost" is not
  # a uniqueness guarantee against a unique index: two namesakes whose IDs end in
  # the same four digits compute the SAME slug, and `Person.create!` then raises
  # RecordNotUnique. So four digits is a PREFERENCE — when that slug already
  # belongs to someone else, widen to the whole identifier, which is unique
  # because the identifier is. It takes THREE namesakes to reach, because the
  # first keeps the clean slug and never computes a suffix at all.
  #
  # Widening is deterministic only because `ordered` is: the namesakes arrive in
  # an order fixed by their identifiers, so the same one widens on every run.
  # Returns nil when nothing is free, which the caller refuses and records.
  def disambiguator_for(identifiers, first, last)
    source = DISAMBIGUATOR_PRIORITY.filter_map { |column| identifiers[column].presence }.first
    return if source.blank?

    disambiguator_candidates(source).find do |candidate|
      !Person.exists?(slug: namesake_slug(first, last, candidate))
    end
  end

  # Shortest first, then the whole identifier. Both are a function of the source
  # ID alone, so the ladder cannot drift between runs.
  def disambiguator_candidates(source)
    digits = source.to_s.gsub(/\D/, "")
    return [digits.last(4), digits].uniq if digits.present?

    alnum = source.to_s.gsub(/[^a-z0-9]/i, "").downcase
    alnum.present? ? [alnum.last(8), alnum].uniq : []
  end

  # Ask Person for the slug rather than re-deriving it here. Re-deriving would be
  # a second copy of `name_slug`'s rule, free to drift from the one that actually
  # writes the column — and this check is only worth making if it tests the slug
  # really about to be inserted. (Sluggable DERIVES `slug` in a before_save, so a
  # `slug:` passed to `new` is ignored; `name_slug` is the only honest source.)
  def namesake_slug(first, last, candidate)
    Person.new(first_name: first, last_name: last, disambiguator: candidate).name_slug
  end

  def build_attrs(row, gsis_id)
    espn_id = row["espn_id"].to_s.strip.presence
    team_abbr = row["latest_team"].to_s.strip.upcase

    {
      gsis_id:           gsis_id,
      pff_id:            row["pff_id"].to_s.strip.presence&.to_i,
      otc_id:            row["otc_id"].to_s.strip.presence,
      espn_id:           espn_id,
      pfr_id:            row["pfr_id"].to_s.strip.presence,
      nflverse_id:       row["nfl_id"].to_s.strip.presence,
      position:          resolve_position(row),
      height_inches:     row["height"].to_s.strip.presence&.to_i,
      weight_lbs:        row["weight"].to_s.strip.presence&.to_i,
      jersey_number:     row["jersey_number"].to_s.strip.presence&.to_i,
      college_name:      row["college_name"].to_s.strip.presence,
      draft_year:        row["draft_year"].to_s.strip.presence&.to_i,
      draft_round:       row["draft_round"].to_s.strip.presence&.to_i,
      draft_pick:        row["draft_pick"].to_s.strip.presence&.to_i,
      team_slug:         TEAM_ABBR_TO_SLUG[team_abbr],
      espn_headshot_url: (espn_id && "https://a.espncdn.com/i/headshots/nfl/players/full/#{espn_id}.png")
    }
  end

  # Prefer pff_position over the generic position column. nflverse's `position`
  # collapses 3-4 and 4-3 outside linebackers into "OLB", which NFLVERSE_MAP
  # collapses further into "LB" — so true edge rushers (T.J. Watt, Maxx Crosby)
  # end up tagged LB and never reach the EDGE pool. PFF disambiguates: "ED" for
  # edge, "DI" for interior, "LB" for off-ball.
  def resolve_position(row)
    pff_pos = row["pff_position"].to_s.strip.presence
    return PositionConcern.normalize_position(pff_pos, source: :pff) if pff_pos

    PositionConcern.normalize_position(row["position"], source: :nflverse)
  end

  # Headshots land under the athlete's team folder so a trade reads clearly in
  # S3; free agents share one folder rather than scattering at the root.
  def cache_headshot(athlete)
    folder = athlete.team_slug.presence || "free-agents"
    Studio::ImageCache.cache!(
      owner: athlete,
      purpose: "headshot",
      source_url: athlete.espn_headshot_url,
      key_prefix: "headshots/nfl/#{folder}/#{athlete.person_slug}",
      widths: HEADSHOT_WIDTHS,
      content_type: "image/png"
    )
    @stats[:headshots_cached] += 1
  rescue StandardError => e
    @stats[:headshots_failed] += 1
    vputs "  [!] headshot fail #{athlete.person_slug}: #{e.message}"
  end

  def parse_csv
    CSV.parse(@csv_body || fetch_remote, headers: true)
  end

  def fetch_remote
    puts "Fetching #{@source_url}"
    URI.open(@source_url, read_timeout: 60).read.force_encoding("UTF-8")
  end

  def vputs(msg)
    puts msg if @verbose
  end
end
