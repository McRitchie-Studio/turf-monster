require "test_helper"

# [unit] Nflverse::SeedPlayers — the identity importer.
#
# Every test here drives ingest_row directly with a hand-built CSV row rather
# than the 7MB live feed, so the suite never touches the network. Headshot
# caching is off throughout (it needs AWS and is covered by its own rake task).
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

  private

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
