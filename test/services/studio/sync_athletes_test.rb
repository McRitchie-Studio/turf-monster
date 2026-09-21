require "test_helper"

# [integration] The replica half of the MS → turf-monster projection.
#
# Every property here is about the same thing: this app settles contests people
# paid to enter, so the sync may be LATE but must never be WRONG and must never
# take the app down.
class Studio::SyncAthletesTest < ActiveSupport::TestCase
  setup do
    Athlete.delete_all
    Person.where(last_name: "Remote").delete_all
    SyncCursor.delete_all
    ENV["AGENT_API_SECRET"] = "shh"
  end

  teardown { ENV.delete("AGENT_API_SECRET") }

  def row(n, updated_at: Time.current, position: "QB", team: "cincinnati-bengals")
    { "gsis_id" => "00-00#{format('%05d', n)}", "person_slug" => "p#{n}-remote",
      "first_name" => "P#{n}", "last_name" => "Remote", "sport" => "football",
      "position" => position, "team_slug" => team, "espn_id" => "e#{n}",
      "updated_at" => updated_at.iso8601(6) }
  end

  # Stubs only the TRANSPORT; everything above the socket is the real service.
  def syncer(pages:, full: false)
    s = Studio::SyncAthletes.new(secret: "shh", full: full)
    queue = pages.dup
    s.define_singleton_method(:authenticate) { "tok" }
    s.define_singleton_method(:fetch) do |_token, _since, _after|
      queue.shift || { "data" => [], "meta" => { "more" => false } }
    end
    s
  end

  def page(rows, more: false)
    last = rows.last
    { "data" => rows,
      "meta" => { "more" => more, "next_updated_since" => last && last["updated_at"],
                  "next_after_id" => rows.length } }
  end

  test "an unconfigured stack skips rather than failing" do
    ENV.delete("AGENT_API_SECRET")

    result = Studio::SyncAthletes.new(secret: nil).call

    assert_equal "skipped", result.status
    assert_equal "skipped", SyncCursor.for("studio_athletes").last_status
  end

  test "creates the person and athlete from a row" do
    syncer(pages: [page([row(1)])]).call

    athlete = Athlete.find_by(gsis_id: "00-0000001")
    assert athlete
    assert_equal "cincinnati-bengals", athlete.team_slug
    assert_equal "P1 Remote", athlete.person.full_name
    assert athlete.synced_at.present?
  end

  # THE SYNC KEY. A slug changes the moment a namesake forces a disambiguator
  # onto it; keyed on slug, a rename would fork one player into two rows.
  test "a changed slug updates the same athlete rather than forking it" do
    syncer(pages: [page([row(1)])]).call
    renamed = row(1).merge("person_slug" => "p1-remote-9075", "position" => "WR")

    assert_no_difference -> { Athlete.count } do
      syncer(pages: [page([renamed])]).call
    end
    assert_equal "WR", Athlete.find_by(gsis_id: "00-0000001").position
  end

  test "a row with no league id is skipped, not guessed at" do
    assert_no_difference -> { Athlete.count } do
      syncer(pages: [page([row(1).merge("gsis_id" => "")])]).call
    end
  end

  # Paging must terminate and cover every row.
  test "pages until the provider says there is no more" do
    first = page([row(1), row(2)], more: true)
    second = page([row(3)], more: false)

    result = syncer(pages: [first, second]).call

    assert_equal 3, result.rows_seen
    assert_equal 2, result.pages
    assert_equal 3, Athlete.count
  end

  test "the watermark advances so a later run resumes" do
    syncer(pages: [page([row(1)])]).call

    cursor = SyncCursor.for("studio_athletes")
    assert cursor.watermark_updated_at.present?
    assert_equal "ok", cursor.last_status
  end

  test "a full run ignores the stored watermark" do
    SyncCursor.for("studio_athletes").update!(watermark_updated_at: 1.day.from_now)

    s = syncer(pages: [page([row(1)])], full: true)
    asked = []
    # Captured OUTSIDE the block: inside define_singleton_method, `self` is the
    # service, not the test case.
    fixed_page = page([row(1)])
    s.define_singleton_method(:fetch) { |_t, since, _a| asked << since; fixed_page }
    s.call

    assert_nil asked.first, "a full rebuild must start from a nil watermark"
  end

  # THE PROPERTY THAT PROTECTS THE APP. A provider outage is late data, not an
  # outage here — this never runs in a request path and must never raise.
  test "the provider being down does not raise" do
    s = Studio::SyncAthletes.new(secret: "shh")
    s.define_singleton_method(:authenticate) { raise Studio::SyncAthletes::Error, "studio unreachable: SocketError" }

    result = nil
    assert_nothing_raised { result = s.call }
    assert_equal "failed", result.status
  end

  test "a provider outage is recorded on the cursor, not swallowed silently" do
    s = Studio::SyncAthletes.new(secret: "shh")
    s.define_singleton_method(:authenticate) { raise Studio::SyncAthletes::Error, "studio unreachable: SocketError" }
    s.call

    cursor = SyncCursor.for("studio_athletes")
    assert_equal "failed", cursor.last_status
    assert_match(/unreachable/, cursor.detail)
  end

  # A replica that is only CONVENTIONALLY read-only becomes a second master by
  # accident — someone edits a name here, the next sync overwrites it, and
  # nobody can say which was right.
  # THE PRODUCTION COLLISION, reproduced. This is the shape review measured on
  # turf-monster-mainnet: the master holds a person under one league id, we hold
  # a DIFFERENT human under the same slug and a different one. Adopting blindly
  # overwrote ours, silently — nothing raised, because there are zero unique
  # collisions between the two tables, and the Person row is untouched so the
  # page kept showing the right name.
  test "a row whose slug belongs to a DIFFERENT league id is refused, not adopted" do
    # Named so Sluggable DERIVES "p1-remote" — the slug row(1) carries. Passing
    # `slug:` here does nothing: the generator overwrites it from the name, and
    # an earlier draft of this test silently created a non-colliding fixture.
    ours = Person.create!(first_name: "P1", last_name: "Remote")
    assert_equal "p1-remote", ours.slug, "the control: the fixture must actually collide"
    mine = Athlete.new(person_slug: ours.slug, sport: "football")
    mine.syncing = true
    mine.gsis_id = "00-0038661"
    mine.position = "LB"
    mine.save!

    theirs = row(1).merge("gsis_id" => "00-0038602", "position" => "WR")
    result = syncer(pages: [ page([ theirs ]) ]).call

    mine.reload
    assert_equal "00-0038661", mine.gsis_id, "OUR athlete's league id must be untouched"
    assert_equal "LB", mine.position, "and so must the rest of him"
    assert_equal 1, Athlete.count, "no twin was created either — person_slug is unique"

    assert result.collided?, "the refusal must be REPORTED, not silently swallowed"
    assert_equal [ { person_slug: "p1-remote", ours: "00-0038661", theirs: "00-0038602" } ],
                 result.collisions
    assert_equal "ok_with_collisions", result.status
    assert_equal 0, result.rows_written, "a refused row is not a write"
  end

  # The other side of the same predicate: an UNIDENTIFIED local row for this
  # name — a seed, or hand-entered — is exactly what the sync exists to adopt.
  # Without this, the guard above would be indistinguishable from "never adopt".
  test "a local athlete with NO league id is still adopted" do
    ours = Person.create!(first_name: "P2", last_name: "Remote")
    assert_equal "p2-remote", ours.slug, "the control: the fixture must be the row's own person"
    blank = Athlete.new(person_slug: ours.slug, sport: "football")
    blank.syncing = true
    blank.save!

    result = syncer(pages: [ page([ row(2) ]) ]).call

    assert_equal "00-0000002", blank.reload.gsis_id, "an unidentified row must be adopted, not refused"
    assert_equal 1, Athlete.count
    refute result.collided?
    assert_equal 1, result.rows_written
  end

  # THE TWO LISTS MUST NOT DRIFT. The write guard refuses exactly the columns
  # McRitchie Studio owns; the projection sends exactly those columns. If a
  # field is added to one and not the other, either a mastered column becomes
  # locally writable or a local column becomes unwritable — and the second is
  # what locked out this app's own nflverse importer.
  test "the guard's mastered set is exactly what the projection sends" do
    # attributes_from `.compact`s, so its key set depends on the INPUT. Feed it
    # a row with every field populated, or this measures the fixture rather than
    # the projection — the first draft did, and compared 5 keys against 13.
    full = row(1).merge(
      "height_inches" => 74, "weight_lbs" => 210, "espn_headshot_url" => "http://x/i.png",
      "nflverse_id" => "n1", "pff_id" => 1, "otc_id" => "o1", "pfr_id" => "r1", "sleeper_id" => "s1"
    )
    sent = Studio::SyncAthletes.new(secret: "shh").send(:attributes_from, full).keys.map(&:to_s).sort

    assert_equal 13, sent.length, "the control: every mastered field must be present in the fixture"

    assert_equal sent, Athlete::STUDIO_MASTERED.sort,
                 "Athlete::STUDIO_MASTERED and SyncAthletes#attributes_from have drifted"
  end

  # A crashed run must not read as a quiet one. The rescue was narrow enough
  # that any ActiveRecord exception escaped `call`, so the cursor kept
  # last_status "ok" and a dead sync looked like a sync that found nothing.
  test "an unexpected error is recorded on the cursor, not escaped" do
    s = syncer(pages: [ page([ row(1) ]) ])
    s.define_singleton_method(:upsert) { |_row| raise ActiveRecord::StatementInvalid, "connection gone" }

    result = nil
    assert_nothing_raised { result = s.call }

    assert_equal "failed", result.status
    cursor = SyncCursor.for(Studio::SyncAthletes::SOURCE)
    assert_equal "failed", cursor.last_status, "a crashed run must not leave the cursor reading ok"
    assert_equal "ActiveRecord::StatementInvalid", cursor.detail,
                 "a foreign exception is recorded by CLASS — its message may quote its input"
  end

  test "a synced athlete refuses a local write" do
    syncer(pages: [page([row(1)])]).call
    athlete = Athlete.find_by(gsis_id: "00-0000001")

    athlete.position = "TE"
    assert_raises(ActiveRecord::ReadOnlyRecord) { athlete.save! }
  end

  test "the sync itself may still write" do
    syncer(pages: [page([row(1)])]).call
    syncer(pages: [page([row(1, position: "WR")])]).call

    assert_equal "WR", Athlete.find_by(gsis_id: "00-0000001").position
  end

  test "an athlete this app created locally is still editable" do
    person = Person.create!(first_name: "Local", last_name: "Remote", athlete: true)
    local = Athlete.create!(person_slug: person.slug, sport: "football")

    local.position = "K"
    assert_nothing_raised { local.save! }
  end

  test "re-syncing unchanged rows reports nothing written" do
    syncer(pages: [page([row(1)])]).call
    result = syncer(pages: [page([row(1)])]).call

    assert_equal 1, result.rows_seen
    assert_equal 0, result.rows_written, "an unchanged row must not count as a write"
  end
end
