require "test_helper"

# [unit] Athlete — the playing profile, its scopes, and its display helpers.
class AthleteTest < ActiveSupport::TestCase
  test "belongs to its person through the slug FK" do
    assert_equal "Pat Passer", athletes(:passer).person.full_name
    assert_equal "Pat Passer", athletes(:passer).full_name
  end

  test "belongs to a team through the slug FK, optionally" do
    assert_equal "Team A", athletes(:passer).team.name
    assert_nil athletes(:suffixed).team, "a free agent has no team and must not raise"
  end

  test "one athlete per person" do
    duplicate = Athlete.new(person_slug: "pat-passer", sport: "football")
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:person_slug], "has already been taken"
  end

  test "sport is required" do
    assert_not Athlete.new(person_slug: "nobody").valid?
  end

  test "the slug derives from the person slug" do
    # A fresh Person: every people fixture already owns an athlete, and the
    # one-athlete-per-person rule would reject a second.
    person = Person.create!(first_name: "Newly", last_name: "Signed")
    athlete = Athlete.create!(person_slug: person.slug, sport: "football")
    assert_equal "newly-signed-athlete", athlete.slug
  end

  test "height_display formats inches as feet and inches" do
    assert_equal %(6'5"), athletes(:passer).height_display
    assert_equal %(5'10"), Athlete.new(height_inches: 70).height_display
    assert_equal %(6'0"), Athlete.new(height_inches: 72).height_display
  end

  test "height_display is nil rather than 0'0\" when unknown" do
    assert_nil Athlete.new(height_inches: nil).height_display
    assert_nil Athlete.new(height_inches: 0).height_display
  end

  test "headshot_url returns the variant asked for" do
    assert_includes athletes(:passer).headshot_url(width: 100), "/100.png"
    assert_includes athletes(:passer).headshot_url(width: 400), "/400.png"
  end

  test "headshot_url is nil when that variant was never cached" do
    assert_nil athletes(:passer).headshot_url(width: 999)
    assert_nil athletes(:rusher).headshot_url,
      "an athlete with no cached image has no URL — callers render initials"
  end

  test "on_a_team excludes free agents" do
    assert_includes Athlete.on_a_team, athletes(:passer)
    assert_not_includes Athlete.on_a_team, athletes(:suffixed)
  end

  test "in_roster_order sorts by position before name" do
    order = Athlete.for_team("team-a").in_roster_order.map(&:position)
    assert_equal %w[QB LT], order

    # Guard the precedence explicitly: sorting by name first would invert this,
    # because Blocker sorts before Passer.
    names = Athlete.for_team("team-a").in_roster_order.map { |a| a.person.last_name }
    assert_equal %w[Passer Blocker], names
  end

  test "in_roster_order puts an unrecognized position last rather than dropping it" do
    person = Person.create!(first_name: "Odd", last_name: "Position")
    Athlete.create!(person_slug: person.slug, sport: "football",
                    team_slug: "team-a", position: "ZZ")

    positions = Athlete.for_team("team-a").in_roster_order.map(&:position)
    assert_equal "ZZ", positions.last
    assert_equal 3, positions.size, "the unknown position is ordered last, not filtered out"
  end

  test "destroying an athlete takes its cached image rows with it" do
    assert_difference "ImageCache.count", -2 do
      athletes(:passer).destroy
    end
  end
end
