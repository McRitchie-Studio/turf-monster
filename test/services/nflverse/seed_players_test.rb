require "test_helper"

# [unit] Nflverse::SeedPlayers — the identity importer.
#
# Every test here drives ingest_row directly with a hand-built CSV row rather
# than the 7MB live feed, so the suite never touches the network. Headshot
# caching is off except where a test stubs the uploader and says so.
class Nflverse::SeedPlayersTest < ActiveSupport::TestCase
  # A row shaped like the real players.csv. Only the columns the importer reads
  # are present; the live file has ~40.
  def row(**overrides)
    defaults = {
      "gsis_id" => "00-0099999", "nfl_id" => "99999",
      "pff_id" => "9999", "otc_id" => "otc-9999",
      "espn_id" => "4099999", "pfr_id" => "PfrX00",
      "common_first_name" => "Rookie", "first_name" => "Rookford",
      "last_name" => "Newman", "status" => "ACT", "last_season" => "2026",
      "position" => "WR", "pff_position" => nil,
      "height" => "73", "weight" => "200", "jersey_number" => "11",
      "college_name" => "Test Tech", "latest_team" => "BUF",
      "draft_year" => "2026", "draft_round" => "2", "draft_pick" => "44"
    }
    CSV::Row.new(*defaults.merge(overrides.transform_keys(&:to_s)).to_a.transpose)
  end

  def seeder
    Nflverse::SeedPlayers.new(upload_headshots: false)
  end

  test "creates a Person and an Athlete from one row" do
    athlete = nil
    assert_difference ["Person.count", "Athlete.count"], 1 do
      athlete = seeder.ingest_row(row)
    end

    assert_equal "rookie-newman", athlete.person_slug
    assert_equal "Rookie Newman", athlete.person.full_name
    assert athlete.person.athlete?, "an nflverse row is by definition an athlete"
    assert_equal "football", athlete.sport
  end

  # THE PATH THE GUARD ACTUALLY BREAKS, and the one no test covered.
  #
  # build_attrs writes 16 columns and 11 are STUDIO_MASTERED. `update!` is
  # ATOMIC, so on a SYNCED athlete the write-guard refuses the whole call and
  # the five columns this importer owns go down with it. Narrowing the guard
  # was not enough on its own — measured, the write still raised and
  # college/draft/jersey all stayed nil, which is verbatim the
  # "Drafted: Undrafted forever" symptom the narrowing was meant to cure.
  #
  # The earlier end-to-end check missed it by writing LOCAL COLUMNS ONLY —
  # the one shape this importer never produces.
  test "a SYNCED athlete still receives the columns this importer owns" do
    person = Person.create!(first_name: "Rookie", last_name: "Newman")
    synced = Athlete.new(person_slug: person.slug, sport: "football")
    synced.syncing = true
    synced.gsis_id = "00-0099999"
    synced.position = "QB"          # master-owned, and deliberately WRONG for the row
    synced.synced_at = Time.current
    synced.save!

    assert_nothing_raised { seeder.send(:ingest_row, row) }

    got = Athlete.find_by(person_slug: person.slug)
    assert_equal "Test Tech", got.college_name, "the importer's OWN column must land"
    assert_equal 2026, got.draft_year
    assert_equal 2, got.draft_round
    assert_equal 44, got.draft_pick
    assert_equal 11, got.jersey_number

    assert_equal "QB", got.position,
                 "a master-owned column must NOT be overwritten by the local importer"
    assert_equal "00-0099999", got.gsis_id
  end

  # The control: on an UNSYNCED row the importer still owns everything, or the
  # deferral above would be indistinguishable from "never writes mastered".
  # A synced athlete must still get its headshot cached: `attrs` is excepted of
  # every mastered column there, so a condition read off it is always nil — and
  # headshot_url has no fallback, so the miss renders as initials, permanently.
  test "a SYNCED athlete still gets its headshot cached" do
    person = Person.create!(first_name: "Rookie", last_name: "Newman")
    synced = Athlete.new(person_slug: person.slug, sport: "football", gsis_id: "00-0099999")
    synced.syncing = true
    synced.espn_headshot_url = "https://a.espncdn.com/i/headshots/nfl/players/full/4099999.png"
    synced.synced_at = Time.current
    synced.save!
    s = seeder                                         # set after construction so the
    s.instance_variable_set(:@upload_headshots, true)  # AWS guard stays out of this test
    cached = []
    Studio::ImageCache.stub(:cache!, ->(**kw) { cached << kw[:owner].person_slug }) do
      s.send(:ingest_row, row)
    end
    assert_equal [ person.slug ], cached, "a synced athlete's headshot must still be cached"
  end

  test "an UNSYNCED athlete still receives every column, mastered included" do
    seeder.send(:ingest_row, row)

    got = Athlete.find_by(gsis_id: "00-0099999")
    assert_equal "WR", got.position, "with no sync in play the importer owns the lot"
    assert_equal "Test Tech", got.college_name
    assert_nil got.synced_at
  end

  test "prefers common_first_name over first_name" do
    # nflverse carries both; the common name is what a broadcast says.
    athlete = seeder.ingest_row(row("common_first_name" => "Rookie", "first_name" => "Rookford"))
    assert_equal "Rookie", athlete.person.first_name
  end

  test "maps the nflverse team abbreviation to this app's team slug" do
    assert_equal "buffalo-bills", seeder.ingest_row(row("latest_team" => "BUF")).team_slug
    # The four quirky abbreviations nflverse uses.
    assert_equal "los-angeles-rams",     seeder.ingest_row(row(**unique, "latest_team" => "LA")).team_slug
    assert_equal "los-angeles-chargers", seeder.ingest_row(row(**unique, "latest_team" => "LAC")).team_slug
    assert_equal "las-vegas-raiders",    seeder.ingest_row(row(**unique, "latest_team" => "LV")).team_slug
    assert_equal "washington-commanders", seeder.ingest_row(row(**unique, "latest_team" => "WAS")).team_slug
  end

  test "an unknown team abbreviation leaves the athlete team-less rather than failing" do
    athlete = seeder.ingest_row(row("latest_team" => "ZZZ"))
    assert_nil athlete.team_slug
  end

  test "carries physical, draft, and college attributes across" do
    athlete = seeder.ingest_row(row)

    assert_equal 73, athlete.height_inches
    assert_equal 200, athlete.weight_lbs
    assert_equal 11, athlete.jersey_number
    assert_equal "Test Tech", athlete.college_name
    assert_equal [2026, 2, 44], [athlete.draft_year, athlete.draft_round, athlete.draft_pick]
  end

  test "builds the ESPN headshot URL from espn_id" do
    athlete = seeder.ingest_row(row("espn_id" => "4040404"))
    assert_equal "https://a.espncdn.com/i/headshots/nfl/players/full/4040404.png",
                 athlete.espn_headshot_url
  end

  test "no espn_id means no headshot URL rather than a broken one" do
    athlete = seeder.ingest_row(row("espn_id" => nil))
    assert_nil athlete.espn_headshot_url
  end

  # The reason the ID hierarchy exists. Sources disagree about suffixes, so a
  # name match would create a second Person for the same human. Matching on a
  # cross-reference ID instead keeps them one record.
  test "a second row for the same player updates rather than duplicating" do
    first = seeder.ingest_row(row("last_name" => "Newman", "position" => "WR"))

    assert_no_difference ["Person.count", "Athlete.count"] do
      # Same gsis_id, different spelling of the name entirely.
      second = seeder.ingest_row(row("common_first_name" => "R.", "last_name" => "Newman Jr.", "position" => "RB"))
      assert_equal first.id, second.id
    end

    assert_equal "RB", first.reload.position, "the later row's position should win"
  end

  test "matches on pff_id when gsis_id is absent" do
    first = seeder.ingest_row(row)

    assert_no_difference "Athlete.count" do
      matched = seeder.ingest_row(row("gsis_id" => nil, "last_name" => "Different"))
      assert_equal first.id, matched.id
    end
  end

  test "a row with no usable name is skipped, not half-created" do
    assert_no_difference ["Person.count", "Athlete.count"] do
      assert_nil seeder.ingest_row(row("common_first_name" => nil, "first_name" => "", "last_name" => ""))
    end
  end

  # pff_position is preferred because nflverse's `position` collapses 3-4 and
  # 4-3 outside linebackers into "OLB", which NFLVERSE_MAP then flattens to
  # "LB" — burying every true edge rusher.
  test "pff_position wins over the generic position column" do
    athlete = seeder.ingest_row(row("position" => "OLB", "pff_position" => "ED"))
    assert_equal "EDGE", athlete.position

    other = seeder.ingest_row(row(**unique, "position" => "OLB", "pff_position" => nil))
    assert_equal "LB", other.position, "without PFF's read, nflverse OLB flattens to LB"
  end

  # THE NAMESAKE CASE. Two active players share a name in seven pairs across the
  # 2026 league. Before this was handled, the second row of each pair matched the
  # first player's Person BY NAME, found their Athlete, and overwrote it — the
  # Vikings' Justin Jefferson was replaced by a Browns linebacker and vanished.
  test "two different players sharing a name both survive" do
    wr = seeder.ingest_row(row(
      "common_first_name" => "Justin", "last_name" => "Jefferson",
      "gsis_id" => "00-0036322", "pff_id" => "60001", "otc_id" => "otc-jj1",
      "espn_id" => "4262921", "pfr_id" => "JeffJu00", "nfl_id" => "52481",
      "position" => "WR", "latest_team" => "MIN"
    ))

    lb = seeder.ingest_row(row(
      "common_first_name" => "Justin", "last_name" => "Jefferson",
      "gsis_id" => "00-0041075", "pff_id" => "60002", "otc_id" => "otc-jj2",
      "espn_id" => "4429987", "pfr_id" => "JeffJu01", "nfl_id" => "58122",
      "position" => "LB", "latest_team" => "CLE"
    ))

    assert_not_equal wr.id, lb.id, "two humans, two Athlete rows"
    assert_equal "00-0036322", wr.reload.gsis_id, "the first player must not be overwritten"
    assert_equal "00-0041075", lb.gsis_id
    assert_equal ["minnesota-vikings", "cleveland-browns"], [wr.team_slug, lb.team_slug]
    assert_equal %w[WR LB], [wr.position, lb.position]
  end

  test "the namesake gets a stable disambiguated slug, the first keeps the clean one" do
    seeder.ingest_row(row(**unique, "common_first_name" => "Justin", "last_name" => "Jefferson"))
    lb = seeder.ingest_row(row(**unique, "common_first_name" => "Justin", "last_name" => "Jefferson",
                               "gsis_id" => "00-0041075"))

    assert_equal "justin-jefferson-1075", lb.person.slug
    assert Person.exists?(slug: "justin-jefferson"), "the first player keeps the clean slug"
  end

  test "the disambiguator is derived from the ID, not from insert order" do
    # Re-deriving must be stable: seeding in a different order has to produce
    # the same slug, or every re-seed would churn public URLs.
    seeder.ingest_row(row(**unique, "common_first_name" => "Justin", "last_name" => "Jefferson"))
    first_run = seeder.ingest_row(row(**unique, "common_first_name" => "Justin",
                                      "last_name" => "Jefferson", "gsis_id" => "00-0041075")).person.slug

    Person.destroy_all
    Athlete.destroy_all

    seeder.ingest_row(row(**unique, "common_first_name" => "Justin", "last_name" => "Jefferson"))
    second_run = seeder.ingest_row(row(**unique, "common_first_name" => "Justin",
                                       "last_name" => "Jefferson", "gsis_id" => "00-0041075")).person.slug

    assert_equal first_run, second_run
  end

  # The other side of the rule: an athlete record that carries NO league ID is
  # an unidentified stub (the offline demo seed, or a hand-entered row), and the
  # importer must ADOPT it rather than create a second record for the same human.
  test "an unidentified athlete for the same name is adopted, not duplicated" do
    person = Person.find_or_create_by_name!("Rookie", "Newman", athlete: true)
    stub = Athlete.create!(person_slug: person.slug, sport: "football", position: "WR")

    assert_no_difference ["Person.count", "Athlete.count"] do
      adopted = seeder.ingest_row(row)
      assert_equal stub.id, adopted.id
    end

    assert_equal "00-0099999", stub.reload.gsis_id, "the stub is filled in, not bypassed"
  end

  test "re-running the seed does not re-collide an already-disambiguated namesake" do
    seeder.ingest_row(row(**unique, "common_first_name" => "Justin", "last_name" => "Jefferson"))
    seeder.ingest_row(row(**unique, "common_first_name" => "Justin", "last_name" => "Jefferson",
                          "gsis_id" => "00-0041075"))

    before = [Person.count, Athlete.count]

    # Same two rows again — the ID hierarchy should now match both directly.
    seeder.ingest_row(row(**unique, "common_first_name" => "Justin", "last_name" => "Jefferson",
                          "gsis_id" => "00-0041075"))

    assert_equal before, [Person.count, Athlete.count]
  end

  test "the constructor refuses to run headshots without AWS credentials" do
    ENV.stub :[], nil do
      error = assert_raises(RuntimeError) { Nflverse::SeedPlayers.new(upload_headshots: true) }
      assert_match(/AWS_ACCESS_KEY_ID/, error.message)
    end
  end

  test "call filters by status and last_season" do
    csv = <<~CSV
      gsis_id,common_first_name,first_name,last_name,status,last_season,position,latest_team,espn_id
      00-0000101,Active,Active,Now,ACT,2026,WR,BUF,101
      00-0000102,Retired,Retired,Long,RET,2019,WR,BUF,102
      00-0000103,Active,Active,Butold,ACT,2019,WR,BUF,103
    CSV

    stats = Nflverse::SeedPlayers.new(
      upload_headshots: false, csv_body: csv, min_season: 2026, status_filter: "ACT"
    ).call

    assert_equal 1, stats[:athletes_created], "only the active 2026 row should land"
    assert_equal 1, stats[:skipped_inactive]
    assert_equal 1, stats[:skipped_old]
  end

  # THE BUG THIS TASK EXISTS FOR — and the one the namesake tests above cannot
  # see, because every one of them gives both men a gsis_id.
  #
  # The old adopt condition was `existing.gsis_id.blank? || existing.gsis_id ==
  # gsis_id`. Its FIRST branch is true for a blank-GSIS namesake PAIR, and
  # nflverse ships plenty: a player carries no GSIS until he appears in a game,
  # so two undrafted rookies sharing a name both arrive blank. The second row
  # then adopted the first man's Athlete and overwrote him.
  test "two blank-GSIS namesakes stay two humans" do
    wr = seeder.ingest_row(row(
      "gsis_id" => "", "common_first_name" => "Justin", "last_name" => "Jefferson",
      "espn_id" => "4262921", "pff_id" => "60001", "otc_id" => "otc-bg1",
      "pfr_id" => "JeffJu00", "nfl_id" => "52481", "latest_team" => "MIN"
    ))
    lb = seeder.ingest_row(row(
      "gsis_id" => "", "common_first_name" => "Justin", "last_name" => "Jefferson",
      "espn_id" => "4430737", "pff_id" => "60002", "otc_id" => "otc-bg2",
      "pfr_id" => "JeffJu01", "nfl_id" => "58122", "latest_team" => "CLE"
    ))

    assert_not_nil lb, "the second namesake must be created, not merged away"
    assert_not_equal wr.id, lb.id, "two humans, two Athlete rows"
    assert_equal "4262921", wr.reload.espn_id, "the first player must not be overwritten"
    assert_equal "4430737", lb.reload.espn_id
    assert_equal 2, Person.where(last_name: "Jefferson").count
  end

  # ORDER-DEPENDENT IDENTITY — and the reason a COUNT cannot catch it.
  #
  # Both orderings produce two people and two athletes, so every cardinality
  # assertion passes under the swap. What changes is WHICH human owns the clean
  # `justin-jefferson` slug. person_slug is the foreign key this whole schema
  # joins on — grades, stats, headshots, contest picks — so a feed reorder
  # silently hands one man's record to the other on the next rebuild.
  #
  # So assert the MAPPING, not the cardinality. It drives `call` rather than
  # `ingest_row`, because `ordered` is the fix under test and calling
  # `ingest_row` directly would step straight over it.
  test "reversing the two blank-GSIS rows does not swap who owns the clean slug" do
    forward = namesake_mapping(namesake_csv(jefferson_a, jefferson_b))
    clear_jeffersons
    reversed = namesake_mapping(namesake_csv(jefferson_b, jefferson_a))

    assert_equal({ "justin-jefferson" => "4262921", "justin-jefferson-0737" => "4430737" },
                 forward, "the lower ESPN id sorts first and keeps the clean slug")
    assert_equal forward, reversed,
                 "CSV order decided which namesake owned the clean slug — every FK is that slug"
  end

  test "ordered sorts on the whole identifier priority, not the csv row index" do
    service = Nflverse::SeedPlayers.new(upload_headshots: false, csv_body: "")
    rows = [
      { "gsis_id" => "", "espn_id" => "4430737", "marker" => "late-espn" },
      { "gsis_id" => "", "espn_id" => "4262921", "marker" => "early-espn" },
      { "gsis_id" => "00-0036322", "espn_id" => "1", "marker" => "has-gsis" },
      { "gsis_id" => "", "espn_id" => "", "pff_id" => "7", "marker" => "pff-only" },
      { "gsis_id" => "", "espn_id" => "", "marker" => "no-ids" }
    ]

    order = service.send(:ordered, rows).map { |r| r["marker"] }

    assert_equal %w[has-gsis early-espn late-espn pff-only no-ids], order
    assert_equal order, service.send(:ordered, rows.reverse).map { |r| r["marker"] },
                 "the ingest order still depends on how the feed listed the rows"
  end

  # COLLISION-SAFE DISAMBIGUATORS. `digits.last(4)` is a preference, not a
  # uniqueness guarantee: two namesakes whose IDs end in the same four digits
  # compute the same slug and `Person.create!` raises RecordNotUnique — which,
  # in a ~25k-row bulk rake task, drops every row after it.
  #
  # It takes THREE namesakes to reach, because the first keeps the clean slug
  # and never computes a suffix at all.
  test "a third namesake sharing the last four digits widens instead of raising" do
    a = seeder.ingest_row(row(**unique, "gsis_id" => "", "espn_id" => "1110737",
                              "common_first_name" => "Justin", "last_name" => "Jefferson"))
    b = seeder.ingest_row(row(**unique, "gsis_id" => "", "espn_id" => "2220737",
                              "common_first_name" => "Justin", "last_name" => "Jefferson"))
    c = nil
    assert_nothing_raised do
      c = seeder.ingest_row(row(**unique, "gsis_id" => "", "espn_id" => "3330737",
                                "common_first_name" => "Justin", "last_name" => "Jefferson"))
    end

    assert_equal "justin-jefferson", a.person_slug
    assert_equal "justin-jefferson-0737", b.person_slug
    assert_equal "justin-jefferson-3330737", c&.person_slug,
                 "the third must widen to the whole identifier rather than collide on 0737"
    assert_equal 3, Person.where(last_name: "Jefferson").count
  end

  # THE POLICY: skip and RECORD. A namesake carrying no identifier at all cannot
  # be given a stable slug, and a raise here would drop every remaining row of a
  # bulk rebuild. So the row is refused, recorded by name, and the run carries on.
  #
  # The third row is another no-ID row, so it sorts into the same bucket and is
  # ingested AFTER the refusal — otherwise "the run continues" would be proved
  # by a row that had already landed before the refusal happened.
  test "a namesake with no identifier is recorded, and a later row still lands" do
    blank = { "gsis_id" => "", "espn_id" => "", "pff_id" => "",
              "otc_id" => "", "pfr_id" => "", "nfl_id" => "" }
    csv = namesake_csv(
      jefferson_a,
      jefferson_a.merge(blank),
      jefferson_a.merge(blank).merge("common_first_name" => "Other", "first_name" => "Other",
                                     "last_name" => "Guy")
    )

    service = Nflverse::SeedPlayers.new(upload_headshots: false, csv_body: csv)
    stats = nil
    assert_nothing_raised { stats = service.call }

    assert_equal 1, stats[:namesake_collisions_skipped]
    assert_equal 1, service.namesake_collisions.size
    refused = service.namesake_collisions.first
    assert_equal "justin-jefferson", refused[:person_slug]
    assert_equal "Justin Jefferson", refused[:name], "the refusal must NAME the human, not just count"
    assert_equal "4262921", refused[:ours]

    assert_equal 1, Person.where(last_name: "Jefferson").count,
                 "the unslugable namesake must not have merged onto the first"
    assert_equal "4262921", Athlete.find_by(person_slug: "justin-jefferson").espn_id
    assert Person.exists?(slug: "other-guy"), "a row ingested AFTER the refusal must still land"
  end

  # The predicate itself. gsis_id is no longer privileged: ANY shared
  # cross-reference means the same human, and an athlete carrying none at all is
  # the unidentified stub the demo seed leaves behind, which must still adopt.
  test "a conflicting secondary identity refuses name-based adoption" do
    service = Nflverse::SeedPlayers.new(upload_headshots: false, csv_body: "")
    existing = Athlete.new(espn_id: "111", pff_id: 222)
    matching = { gsis_id: nil, espn_id: "111", pff_id: nil,
                 otc_id: nil, pfr_id: nil, nflverse_id: nil }

    assert service.send(:adoptable_name_match?, existing, matching)
    assert_not service.send(:adoptable_name_match?, existing, matching.merge(espn_id: "333"))
    assert service.send(:adoptable_name_match?, Athlete.new, matching.merge(espn_id: "333")),
           "an unidentified hand-entered athlete is still adopted — that is the point of the stub path"
  end

  private

  NAMESAKE_CSV_HEADERS = %w[
    gsis_id nfl_id pff_id otc_id espn_id pfr_id
    common_first_name first_name last_name status last_season position latest_team
  ].freeze

  def jefferson(espn_id:, pff_id:, otc_id:, pfr_id:, nfl_id:, team:)
    { "gsis_id" => "", "nfl_id" => nfl_id, "pff_id" => pff_id, "otc_id" => otc_id,
      "espn_id" => espn_id, "pfr_id" => pfr_id,
      "common_first_name" => "Justin", "first_name" => "Justin", "last_name" => "Jefferson",
      "status" => "ACT", "last_season" => "2026", "position" => "WR", "latest_team" => team }
  end

  def jefferson_a
    jefferson(espn_id: "4262921", pff_id: "60001", otc_id: "otc-ja",
              pfr_id: "JeffJu00", nfl_id: "52481", team: "MIN")
  end

  def jefferson_b
    jefferson(espn_id: "4430737", pff_id: "60002", otc_id: "otc-jb",
              pfr_id: "JeffJu01", nfl_id: "58122", team: "CLE")
  end

  def namesake_csv(*rows)
    CSV.generate do |out|
      out << NAMESAKE_CSV_HEADERS
      rows.each { |r| out << NAMESAKE_CSV_HEADERS.map { |header| r[header] } }
    end
  end

  # slug => espn_id for everyone named Jefferson. The MAPPING is the assertion;
  # the count is not, because both orderings produce the same count.
  def namesake_mapping(csv)
    Nflverse::SeedPlayers.new(upload_headshots: false, csv_body: csv).call
    Athlete.where(person_slug: Person.where(last_name: "Jefferson").select(:slug))
           .to_h { |athlete| [athlete.person_slug, athlete.espn_id] }
  end

  def clear_jeffersons
    Athlete.where(person_slug: Person.where(last_name: "Jefferson").select(:slug)).destroy_all
    Person.where(last_name: "Jefferson").destroy_all
  end

  # Fresh cross-reference IDs so a case that wants a NEW athlete does not get
  # matched onto the previous one by the ID hierarchy.
  def unique
    @seq = (@seq || 0) + 1
    {
      "gsis_id" => "00-001#{format("%04d", @seq)}",
      "pff_id" => "8#{format("%03d", @seq)}",
      "otc_id" => "otc-u#{@seq}",
      "espn_id" => "50#{format("%05d", @seq)}",
      "pfr_id" => "PfrU#{format("%02d", @seq)}",
      # nfl_id feeds athletes.nflverse_id, which also carries a unique index —
      # leaving it at the shared default made every second row collide there
      # and get swallowed by ingest_row's RecordNotUnique rescue.
      "nfl_id" => "9#{format("%05d", @seq)}"
    }
  end
end
