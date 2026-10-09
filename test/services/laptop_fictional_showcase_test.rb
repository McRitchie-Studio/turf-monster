require "test_helper"

# [unit] The hero laptop's FICTIONAL contest (LaptopFictionalShowcase) and its
# render (LaptopLiveSnapshot): built from fixed, in-memory data with no
# database read and no write; the same bytes on any date and whatever real
# contests exist; 49ers over Cowboys in the featured game; and exactly two
# entrants, Mason and Turf.
class LaptopFictionalShowcaseTest < ActiveSupport::TestCase
  # The ONLY queries a render may make: the signed-out navbar's own chrome, the
  # session-less renderer's current_user lookup (no user id) and the geo
  # setting behind the navbar's region pill. Neither reads a contest, a game,
  # an entry or a player.
  CHROME_QUERIES = [
    /\ASELECT "users"\.\* FROM "users" WHERE "users"\."id" IS NULL LIMIT/,
    /\ASELECT "studio_geo_settings"\.\* FROM "studio_geo_settings" WHERE/
  ].freeze

  def queries_during(&)
    sql = []
    callback = lambda do |*, payload|
      next if payload[:name] == "SCHEMA" || payload[:sql].match?(/\A(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/)

      sql << payload[:sql]
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &)
    sql
  end

  def render_all
    snapshot = LaptopLiveSnapshot.new(LaptopFictionalShowcase.build, host: "turf.example", https: true)
    [snapshot.render.to_str, snapshot.frames]
  end

  def text_of(html) = Nokogiri::HTML5.fragment(html).text.squish

  test "the showcase builds from fixed data with no database read" do
    showcase = nil
    assert_empty queries_during { showcase = LaptopFictionalShowcase.build }
    assert_equal "Turf Monster Showcase", showcase.contest.name
    assert_equal "NFL Sunday", showcase.contest.slate.name
    assert_equal 6, showcase.games.values.flatten.size
    assert_empty showcase.entries
  end

  test "the render reads only the signed-out navbar's chrome, never contest data" do
    queries = queries_during { render_all }
    offenders = queries.reject { |sql| CHROME_QUERIES.any? { |re| sql.match?(re) } }
    assert_empty offenders, "only the navbar's chrome queries; got:\n#{offenders.join("\n")}"
  end

  test "every showcase record is unsaved and readonly" do
    showcase = LaptopFictionalShowcase.build
    records = [showcase.contest, showcase.contest.slate, *showcase.games.values.flatten, *showcase.matchups,
               *showcase.matchups.map(&:team)]
    records.each do |record|
      assert record.new_record?, "#{record.class} is never saved"
      assert record.readonly?, "#{record.class} is readonly, so a save raises"
    end
  end

  # THE EVERGREEN RULE: two dates months apart, and a real live contest created
  # between them, and the laptop is the same bytes.
  test "the snapshot renders identically on two dates months apart, whatever real contests exist" do
    before = travel_to(Time.utc(2026, 10, 9, 18)) { render_all }

    slate = Slate.create!(name: "NFL 2027 Weeks 1-3", slug: "nfl-2027-evergreen", sport: "nfl", starts_at: Time.utc(2027, 1, 1))
    contest = Contest.create!(name: "Real Weeks 1-3", slug: "real-weeks-evergreen", status: "open", entry_fee_cents: 1900,
                              max_entries: 29, contest_type: "standard", slate: slate, starts_at: Time.utc(2027, 1, 2))
    contest.entries.create!(user: users(:sam), status: :active)

    after = travel_to(Time.utc(2027, 2, 14, 3)) { render_all }

    assert_equal before[0], after[0], "the snapshot HTML is byte-identical"
    assert_equal before[1], after[1], "every simulated frame is byte-identical"
    refute_includes after[0], "Real Weeks 1-3"
    refute_includes after[0], users(:sam).username
  end

  test "no calendar date or season year is printed, only weekday-and-time kickoffs" do
    html, frames = render_all
    text = text_of(html)
    refute_match(/\b20\d\d\b/, text, "no year")
    refute_match(/\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]* \d/, text, "no calendar date")
    assert_includes text, "Sun 6:20 PM"
    assert_includes text, "Mon 6:15 PM"
    doc = Nokogiri::HTML5.fragment(html)
    assert_empty doc.css("time"), "no <time> for the live script to re-format in the reader's zone"
    frames.each { |frame| refute_match(/\b20\d\d\b/, text_of(frame[:tile])) }
  end

  test "the featured game is the 49ers (top) at the Cowboys (bottom), 3-7" do
    doc = Nokogiri::HTML5.fragment(render_all[0])
    tile = doc.at_css(%([data-test="live-focus-game"][data-focus-slug="#{LaptopFictionalShowcase::FOCUS_SLUG}"]))
    assert tile, "the featured tile"
    rows = tile.css('[data-role="team-row"]').map { |row| row["data-team-slug"] }.uniq
    assert_equal %w[san-francisco-49ers dallas-cowboys], rows, "49ers on top, Cowboys below"
    scores = tile.css('[data-role="team-row"] [data-role="score"]').map { |s| s.text.strip }.first(2)
    assert_equal %w[3 7], scores
  end

  test "the leaderboard holds exactly Mason and Turf, with their avatars" do
    doc = Nokogiri::HTML5.fragment(render_all[0])
    board = doc.at_css('[data-test="laptop-live-leaderboard"]')
    assert_equal %w[showcase-mason showcase-turf], board.css("[data-entry-slug]").map { |r| r["data-entry-slug"] }.uniq
    assert_equal 2, board.css('[data-test="showcase-avatar"]').size
    names = board.css("[data-entry-slug] .font-bold.truncate").map { |n| n.text.strip }.uniq
    assert_equal %w[Mason Turf], names
  end
end
