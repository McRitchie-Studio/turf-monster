require "csv"
require "open-uri"
require "set"

# READ-ONLY audit for athlete rows that merged two human beings into one.
#
# THE INCIDENT THIS EXISTS FOR. Until PR 799, Nflverse::SeedPlayers#resolve_athlete!
# adopted any name-matched athlete whose gsis_id was BLANK. Two humans sharing a
# name, neither carrying a league ID at ingest, therefore collapsed into ONE row:
# the first man's Person keeps the slug and the name, and the second man's gsis_id
# is stamped onto it. The hub lost chris-smith to exactly this, holding 00-0038661.
# PR 799 stops new merges. It does not un-merge what is already stored, and
# turf-monster settles contests people paid to enter — a merged athlete means two
# humans graded as one, so stats, goals and payouts attribute to the wrong person.
#
# WHY THIS IS AN AUDIT AND NOT A REPAIR. `goals.player_slug` is a slug-based FK
# into `players`, and athlete slugs are not player slugs. Re-splitting a merged
# human is both lossy and FK-blocked (see /tasks/retire-tm-players-blocked-by-goals).
# This class reads. It has no write path — see READ-ONLY below.
#
# ── A MERGED ROW LOOKS NORMAL, SO COUNTING CANNOT FIND IT ────────────────────
#
# The row has a slug, a name and a gsis_id. Nothing is null and no constraint is
# violated. A merge leaves the athlete count LOWER, not wrong-looking, and a
# count is blind to a permutation — two rows whose IDs were exchanged count the
# same as two correct rows. So this audit asserts the slug→ID MAPPING itself
# against the source feed, and it does so with two complementary detectors
# because THE MERGE HAS TWO SHAPES and neither detector sees the other's:
#
#   :foreign_id — the row's own name disagrees with the name the feed gives for
#     an ID the row holds. Catches a row that absorbed a DIFFERENTLY-named human,
#     and catches permutations (a swap raises two findings, a count raises none).
#
#   :absorbed_namesake — the row's name AGREES with the feed, and the row is
#     still wrong. This is the chris-smith shape and detector one is blind to it:
#     when both humans share a name, the feed names the stolen ID's owner
#     "Chris Smith" and the row is also "Chris Smith", so the mapping check
#     passes. The tell is elsewhere — the OTHER Chris Smith's gsis_id is held by
#     nobody in turf, while a turf athlete carries his name and a different ID.
#
# Both detectors NAME BOTH HUMANS from a source, never by inference: the
# occupant is read from this database, the other human is read from the feed.
#
# ── READ-ONLY ────────────────────────────────────────────────────────────────
#
# The safety claim is enforced, not documented. Every relation this class opens
# is `.readonly`, so each object it touches raises ActiveRecord::ReadOnlyRecord
# on any save/update/destroy rather than relying on nobody adding one later. The
# claim is then PROVEN behaviourally: test/services/nflverse/merged_row_audit_test.rb
# subscribes to `sql.active_record` across a full run and asserts that not one
# INSERT, UPDATE or DELETE was emitted. Grepping the source for `update` would
# only prove this file's spelling; the subscriber proves the run.
#
# Usage:
#   Nflverse::MergedRowAudit.call                       # fetches the live feed
#   Nflverse::MergedRowAudit.call(csv_body: fixture)    # offline, for tests
#   puts Nflverse::MergedRowAudit.call.to_report
class Nflverse::MergedRowAudit
  PLAYERS_URL = Nflverse::SeedPlayers::PLAYERS_URL
  DEFAULT_MIN_SEASON = Nflverse::SeedPlayers::DEFAULT_MIN_SEASON

  # Athlete ID column => the players.csv column carrying the same identifier.
  # Every one of these is unique to one human in the feed, which is what makes a
  # mismatch meaningful rather than merely surprising.
  FEED_ID_COLUMNS = {
    "gsis_id" => "gsis_id",
    "espn_id" => "espn_id",
    "pff_id" => "pff_id",
    "otc_id" => "otc_id",
    "pfr_id" => "pfr_id",
    "nflverse_id" => "nfl_id"
  }.freeze

  # On `athletes` but NOT in players.csv, so this feed cannot vouch for it and
  # the audit does not pretend to. Named rather than silently omitted: a reader
  # counting six checked columns against seven stored ones deserves the reason.
  UNCHECKABLE_ID_COLUMNS = %w[sleeper_id].freeze

  # Stripped before comparing names. Sources disagree about suffixes — nflverse
  # carries "Will Anderson Jr." where another importer stored "Will Anderson" —
  # and a suffix gap is a spelling difference, not two humans.
  NAME_SUFFIXES = %w[jr jnr sr snr ii iii iv v].freeze

  # kind          :foreign_id or :absorbed_namesake
  # occupant_*    the human this turf row is NAMED for — read from THIS database
  # held_ids      [[column, value], ...] — every identifier pointing at the other human
  # other_*       the second human — read from the FEED, never inferred
  #
  # ONE FINDING PER ATHLETE PER OTHER HUMAN, not per ID column. A merged row
  # holds the absorbed human's whole cross-reference set, so a per-column finding
  # reports one row five or six times. Measured against production: a single
  # flagged row produced five findings, and "findings: 5" reads as five damaged
  # athletes to anyone who does not open the list. The unit of the acceptance
  # criterion is the ATHLETE, so that is the unit of a finding.
  Finding = Struct.new(
    :kind, :athlete_slug, :person_slug, :occupant_name,
    :held_ids, :other_name, :other_gsis_id, :other_status, :other_last_season,
    keyword_init: true
  ) do
    def held_columns = held_ids.map(&:first)
    def held_summary = held_ids.map { |column, value| "#{column}=#{value}" }.join(" ")

    # WOULD THE IMPORTER HAVE MADE HIM A ROW AT ALL? This splits a real lead
    # from an absence that is already explained, and without it the two look
    # identical on the page. Nflverse::SeedPlayers ingests only status=ACT, so a
    # DEV, RES, PUP or CUT human has no row because the importer skipped him —
    # not because a merge swallowed him. Measured against production 2026-09-22:
    # the one candidate raised, anthony-johnson, is status DEV, and reading this
    # field is what turned it from a finding into an explained absence in minutes.
    def missing_row_is_unexplained? = other_status == Feed::INGESTED_STATUS

    def to_line
      case kind
      when :foreign_id
        "#{athlete_slug}  named here: #{occupant_name}  —  the feed says #{held_summary} " \
          "#{held_ids.one? ? "is" : "are all"} #{other_name}"
      when :absorbed_namesake
        "#{athlete_slug}  named here: #{occupant_name}  holds #{held_summary}  —  " \
          "the feed's other #{other_name} (gsis #{other_gsis_id}, " \
          "status #{other_status}, last season #{other_last_season}) has no row at all"
      end
    end
  end

  Result = Struct.new(
    :findings, :athletes_checked, :ids_checked, :unverifiable_ids,
    :unidentified_athletes, :feed_rows, :active_feed_rows, :checked_at,
    keyword_init: true
  ) do
    def foreign_ids = findings.select { |f| f.kind == :foreign_id }
    def absorbed_namesakes = findings.select { |f| f.kind == :absorbed_namesake }
    def clean? = findings.empty?

    # The report states its own blind spots. An audit that prints findings but
    # not its limits invites the reader to treat "0 findings" as "0 merges",
    # which is the one conclusion it cannot support.
    def to_report
      lines = []
      lines << "nflverse merged-row audit — #{checked_at.utc.iso8601}"
      lines << "READ-ONLY. No INSERT, UPDATE or DELETE is issued by this task."
      lines << ""
      lines << "Scanned #{athletes_checked} football athletes · #{ids_checked} stored IDs checked " \
               "against #{feed_rows} feed rows (#{active_feed_rows} in the current league)."
      lines << "#{unverifiable_ids} stored ID(s) matched no feed row — NOT verifiable either way."
      lines << "#{unidentified_athletes} athlete(s) carry no checkable ID at all."
      lines << "Columns checked: #{FEED_ID_COLUMNS.keys.join(', ')}. " \
               "Not checked (absent from this feed): #{UNCHECKABLE_ID_COLUMNS.join(', ')}."
      lines << ""

      lines << "FOREIGN ID — the row's name disagrees with the feed's owner of an ID it holds (#{foreign_ids.size})"
      lines.concat(section(foreign_ids))
      lines << "  Innocent explanation to rule out: a nickname or spelling variant this"
      lines << "  audit's alias check did not cover (\"Chig\" vs \"Chigoziem\")."
      lines << ""

      unexplained, explained = absorbed_namesakes.partition(&:missing_row_is_unexplained?)
      lines << "ABSORBED NAMESAKE — a feed human has no row, and a same-named row holds another ID (#{absorbed_namesakes.size})"
      lines << "  · INVESTIGATE FIRST — the importer ingests status=#{Feed::INGESTED_STATUS}, so these should have a row (#{unexplained.size})"
      lines.concat(section(unexplained))
      lines << "  · absence already explained — the importer skips this status (#{explained.size})"
      lines.concat(section(explained))
      lines << "  These are CANDIDATES, not proof, and even the first group has an"
      lines << "  innocent explanation to rule out: the named human may have signed"
      lines << "  after the last seed run, which reads identically from here."
      lines << ""

      lines << "WHAT THIS AUDIT CANNOT SEE:"
      lines << "  - a merge whose absorbed human is absent from the feed entirely"
      lines << "    (no league ID anywhere) — nothing names him, so nothing flags him"
      lines << "  - which goals, stats or payouts belong to which human on a merged row"
      lines << "  - #{UNCHECKABLE_ID_COLUMNS.join(', ')}, which this feed does not carry"
      lines.join("\n")
    end

    private

    def section(rows)
      return ["  none"] if rows.empty?

      rows.map { |f| "  #{f.to_line}" }
    end
  end

  def self.call(...) = new(...).call

  def initialize(csv_body: nil, source_url: PLAYERS_URL, min_season: DEFAULT_MIN_SEASON)
    @csv_body = csv_body
    @source_url = source_url
    @min_season = min_season.to_i
  end

  def call
    feed = build_feed

    findings = []
    ids_checked = 0
    unverifiable = 0
    unidentified = 0

    people = people_by_slug
    athletes = 0
    held_gsis_ids = Set.new
    by_name = Hash.new { |h, k| h[k] = [] }

    each_athlete do |athlete|
      athletes += 1
      person = people[athlete.person_slug]
      next if person.nil?

      held_gsis_ids << athlete.gsis_id.to_s.strip if athlete.gsis_id.present?
      by_name[normalized(person.first_name, person.last_name)] << [athlete, person]

      checkable = 0
      mismatched = []
      FEED_ID_COLUMNS.each_key do |column|
        value = athlete.public_send(column).to_s.strip
        next if value.empty?

        checkable += 1
        ids_checked += 1
        feed_row = feed.by_id(column, value)
        next unverifiable += 1 if feed_row.nil?
        next if names_agree?(person, feed_row)

        mismatched << [column, value, feed_row]
      end
      unidentified += 1 if checkable.zero?
      findings.concat(foreign_id_findings(feed, athlete, person, mismatched))
    end

    findings.concat(absorbed_namesakes(feed, held_gsis_ids, by_name))

    Result.new(
      findings: findings, athletes_checked: athletes, ids_checked: ids_checked,
      unverifiable_ids: unverifiable, unidentified_athletes: unidentified,
      feed_rows: feed.size, active_feed_rows: feed.current_league.size,
      checked_at: Time.current
    )
  end

  private

  # Collapses one athlete's mismatched IDs into one finding per OTHER HUMAN.
  # Grouping on the feed row's gsis_id rather than on its name, because two
  # different humans can share a name — grouping on the name would merge them
  # back together, which is the very confusion this audit exists to report.
  def foreign_id_findings(feed, athlete, person, mismatched)
    mismatched.group_by { |_column, _value, feed_row| feed_row["gsis_id"].to_s.strip }
              .map do |other_gsis_id, group|
      Finding.new(
        kind: :foreign_id,
        athlete_slug: athlete.slug, person_slug: athlete.person_slug,
        occupant_name: person.full_name,
        held_ids: group.map { |column, value, _row| [column, value] },
        other_name: feed.display_name(group.first.last),
        other_gsis_id: other_gsis_id.presence
      )
    end
  end

  # DETECTOR TWO. Runs over the feed's CURRENT-LEAGUE population — every human
  # with last_season >= min_season, whatever his status says today. Over the full
  # 25k-row historical feed this would fire on every retired player who shares a
  # name with a current one, which is a flood of false positives and not a merge.
  #
  # NOT `status == ACT`, though that is what the importer filters on at seed
  # time, and the difference is most of the audit's reach. Status is a SNAPSHOT
  # and it drifts: a player seeded while ACT is later CUT, RES, PUP or DEV, and
  # the row turf stored does not move with him. Measured against production
  # 2026-09-22 — turf holds 2,896 athletes from a preseason seed, while the feed
  # now calls just 1,731 of them ACT and 2,511 current-league. Scoped to ACT this
  # detector could not see 40% of the population it is auditing, and an absorbed
  # human who has since been cut is exactly the case it would drop.
  #
  # The signature is a CONJUNCTION, and each half alone is innocent: a feed human
  # with no turf row is merely un-imported, and a turf row holding an ID is
  # merely a player. Together — his ID held by nobody, while a row carrying his
  # name holds a DIFFERENT ID — that row is doing double duty for two humans.
  def absorbed_namesakes(feed, held_gsis_ids, by_name)
    feed.current_league.filter_map do |feed_row|
      gsis_id = feed_row["gsis_id"].to_s.strip
      next if gsis_id.empty?
      next if held_gsis_ids.include?(gsis_id)

      # `fetch` with an explicit default, NOT `[]`: `by_name` carries a
      # default_proc that inserts on read, and `[]` here would grow the hash by
      # one empty bucket per unmatched feed row. `fetch` never calls default_proc.
      occupants = by_name.fetch(normalized(*feed.name_parts(feed_row)), [])
      next if occupants.empty?

      athlete, person = occupants.find { |a, p| double_duty?(feed, a, p, gsis_id) }
      next if athlete.nil?

      Finding.new(
        kind: :absorbed_namesake,
        athlete_slug: athlete.slug, person_slug: athlete.person_slug,
        occupant_name: person.full_name,
        held_ids: [["gsis_id", athlete.gsis_id.to_s.strip]],
        other_name: feed.display_name(feed_row), other_gsis_id: gsis_id,
        other_status: feed_row["status"].to_s.strip,
        other_last_season: feed_row["last_season"].to_s.strip
      )
    end
  end

  # Is this row standing in for the unrepresented human as well as its own?
  #
  # The two guards below are what keep this detector from saying more than it
  # read, and each was added for a case that fired wrongly without it:
  #
  #   - the row's OWN gsis_id must resolve in the feed. A row holding an ID the
  #     feed has never heard of is ALREADY counted as unverifiable, and its
  #     occupant's identity is exactly what is unconfirmed — so "he absorbed a
  #     namesake" is a claim about a human this audit cannot vouch for. Measured:
  #     without this, a single-Alice feed produced a finding reading "the feed's
  #     other Alice Ant", when the feed holds only one.
  #
  #   - the row's name must AGREE with its own feed row. If it disagrees,
  #     detector one already owns this row and reporting it twice under a second
  #     heading turns one problem into two.
  #
  # Together they make the detectors partition the findings rather than overlap.
  def double_duty?(feed, athlete, person, unheld_gsis_id)
    held = athlete.gsis_id.to_s.strip
    return false if held.empty? || held == unheld_gsis_id

    own = feed.by_id("gsis_id", held)
    return false if own.nil?

    names_agree?(person, own)
  end

  # A turf row and a feed row name the same human when any spelling either side
  # recorded agrees. The feed carries two (`common_first_name` and `first_name`)
  # and Person carries its own plus every alias a past ingest recorded, so the
  # comparison is deliberately generous: a false accusation of a merge costs a
  # real investigation, and a genuine merge holds two entirely different names
  # rather than a suffix or a period.
  def names_agree?(person, feed_row)
    feed_names = feed_row_spellings(feed_row)
    stored = [normalized(person.first_name, person.last_name)]
    stored.concat(Array(person.aliases).map { |a| normalized(a, nil) })
    (stored & feed_names).any?
  end

  def feed_row_spellings(feed_row)
    last = feed_row["last_name"]
    [
      normalized(feed_row["common_first_name"], last),
      normalized(feed_row["first_name"], last)
    ].uniq.reject(&:empty?)
  end

  def normalized(first, last)
    raw = "#{first} #{last}".to_s.downcase.gsub(/[.'"“”’`]/, "")
    raw.split(/\s+/).reject { |part| NAME_SUFFIXES.include?(part) }.join(" ").parameterize
  end

  # READ-ONLY, ENFORCED. `.readonly` marks every instantiated object, so a
  # save/update/destroy on anything this audit loads raises ReadOnlyRecord
  # instead of depending on this file never growing a writer.
  def each_athlete(&block)
    Athlete.football.readonly.find_each(batch_size: 500, &block)
  end

  def people_by_slug
    Person.readonly.select(:slug, :first_name, :last_name, :aliases).index_by(&:slug)
  end

  def build_feed = Feed.new(parse_csv, min_season: @min_season)

  def parse_csv
    CSV.parse(@csv_body || fetch_remote, headers: true)
  end

  def fetch_remote
    URI.open(@source_url, read_timeout: 60).read.force_encoding("UTF-8")
  end

  # The source feed, indexed by every identifier it carries. Built once per run;
  # the audit asks it ~6 questions per athlete and a linear scan each time would
  # be 25k × 6 × 3k comparisons.
  class Feed
    # The one status Nflverse::SeedPlayers ingests. Named here because a
    # finding's triage depends on it: an absent human who is not ACT was skipped
    # by the importer, and that absence is explained rather than suspicious.
    INGESTED_STATUS = "ACT".freeze

    attr_reader :rows

    def initialize(rows, min_season:)
      @rows = rows
      @min_season = min_season
      @index = FEED_ID_COLUMNS.transform_values { |_csv| {} }
      FEED_ID_COLUMNS.each do |column, csv_column|
        rows.each do |row|
          value = row[csv_column].to_s.strip
          # FIRST WRITER WINS. A duplicate ID in the feed is the feed's own
          # problem; overwriting would make this audit's answer depend on CSV
          # row order, which is not a property anyone should have to reason about.
          @index[column][value] ||= row unless value.empty?
        end
      end
    end

    def by_id(column, value) = @index.dig(column, value.to_s.strip)

    def size = rows.size

    # The humans in the league this season, by SEASON and not by today's status.
    # A blank/zero last_season is included rather than dropped: the column is
    # absent for some rows, and excluding them would silently narrow the audit.
    def current_league
      @current_league ||= rows.select do |row|
        last_season = row["last_season"].to_i
        last_season.zero? || last_season >= @min_season
      end
    end

    # The spelling the importer itself would have used, so a name this audit
    # prints is the name that row would have created.
    def name_parts(row)
      [row["common_first_name"].to_s.strip.presence || row["first_name"].to_s.strip,
       row["last_name"].to_s.strip]
    end

    def display_name(row) = name_parts(row).join(" ").strip
  end
end
