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

  attr_reader :stats

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
  end

  def call
    rows = parse_csv
    puts "  #{rows.size} rows; filter: status=#{@status_filter || "any"} last_season>=#{@min_season}"

    rows.each do |row|
      next @stats[:skipped_inactive] += 1 if @status_filter && row["status"] != @status_filter

      last_season = row["last_season"].to_i
      next @stats[:skipped_old] += 1 if last_season.positive? && last_season < @min_season

      ingest_row(row)
    end

    puts "\nnflverse seed: #{@stats.inspect}"
    @stats
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
    athlete = lookup_athlete_by_ids(gsis_id:, pff_id:, otc_id:, espn_id:, pfr_id:)
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

      athlete = resolve_athlete!(person, first, last, gsis_id, espn_id)
    end

    attrs = build_attrs(row, gsis_id)
    begin
      athlete.update!(attrs.compact)
      @stats[:athletes_updated] += 1
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      @stats[:athletes_failed] += 1
      vputs "  [!] update fail #{person&.slug} (gsis=#{gsis_id}): #{e.message}"
      return nil
    end

    cache_headshot(athlete) if @upload_headshots && attrs[:espn_headshot_url]
    athlete
  end

  private

  def lookup_athlete_by_ids(gsis_id:, pff_id:, otc_id:, espn_id:, pfr_id:)
    return Athlete.find_by(gsis_id:)     if gsis_id && Athlete.exists?(gsis_id:)
    return Athlete.find_by(pff_id:)      if pff_id  && Athlete.exists?(pff_id:)
    return Athlete.find_by(otc_id:)      if otc_id  && Athlete.exists?(otc_id:)
    return Athlete.find_by(espn_id:)     if espn_id && Athlete.exists?(espn_id:)
    return Athlete.find_by(pfr_id:)      if pfr_id  && Athlete.exists?(pfr_id:)

    nil
  end

  # Attach this row to the right Athlete, given a Person matched BY NAME.
  #
  # Reaching here means no cross-reference ID matched, so the Person we just
  # found may not be this human at all — two active players can share a name.
  # Seven pairs do in the 2026 league, and the previous version of this method
  # took `Athlete.find_by(person_slug:)` at face value and let the second of
  # each pair overwrite the first, silently losing seven players.
  #
  # The tell is the existing record's own league ID:
  #   - no athlete yet            -> create one
  #   - athlete with no gsis_id   -> an unidentified record for this name (the
  #                                  offline demo seed, or a hand-entered row);
  #                                  adopt it rather than making a twin
  #   - athlete with a DIFFERENT
  #     gsis_id                   -> a different human who shares the name;
  #                                  give them their own Person, slugged with a
  #                                  disambiguator so the two never collide
  def resolve_athlete!(person, first, last, gsis_id, espn_id)
    existing = Athlete.find_by(person_slug: person.slug)

    if existing && (existing.gsis_id.blank? || existing.gsis_id == gsis_id)
      return existing
    end

    if existing
      person = Person.create!(
        first_name: first, last_name: last, athlete: true,
        disambiguator: disambiguator_for(gsis_id, espn_id)
      )
      @stats[:people_created] += 1
      @stats[:name_collisions] += 1
      vputs "  [~] name collision: #{first} #{last} -> #{person.slug}"
    end

    @stats[:athletes_created] += 1
    Athlete.create!(person_slug: person.slug, sport: "football")
  end

  # A short, STABLE suffix. Derived from the league ID rather than a counter,
  # so re-running the seed in a different row order produces the same slug.
  def disambiguator_for(gsis_id, espn_id)
    source = gsis_id.presence || espn_id.presence
    raise "cannot disambiguate a namesake with no league ID" if source.blank?

    source.gsub(/\D/, "").last(4)
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
