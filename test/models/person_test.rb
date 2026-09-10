require "test_helper"

# [unit] Person — the identity record, and the name matching that keeps one
# human from becoming several records.
#
# The matching matters because every source spells names differently: nflverse
# says "Sam Suffix Jr.", Spotrac drops the suffix, PFF uses initials. A bare
# slug lookup would create a new Person for each spelling and then the grade
# importer would attach to the wrong one.
class PersonTest < ActiveSupport::TestCase
  test "first and last name are required" do
    assert_not Person.new(first_name: "Only").valid?
    assert_not Person.new(last_name: "Only").valid?
  end

  test "the slug derives from the name" do
    person = Person.create!(first_name: "Brand", last_name: "New")
    assert_equal "brand-new", person.slug
  end

  test "find_by_name matches an exact slug" do
    assert_equal people(:passer), Person.find_by_name("Pat", "Passer")
  end

  test "find_by_name matches through punctuation" do
    punctuated = Person.create!(first_name: "TJ", last_name: "Watts")
    assert_equal punctuated, Person.find_by_name("T.J.", "Watts"),
      "periods and apostrophes must not split one player into two records"
  end

  test "find_by_name matches a recorded alias" do
    # The fixture is stored as "Sam Suffix Jr." with "Sam Suffix" as an alias.
    assert_equal people(:suffixed), Person.find_by_name("Sam", "Suffix")
  end

  test "find_by_name returns nil for someone genuinely new" do
    assert_nil Person.find_by_name("Nobody", "Here")
  end

  test "find_or_create_by_name! creates when there is no match" do
    assert_difference "Person.count", 1 do
      person = Person.find_or_create_by_name!("Fresh", "Face", athlete: true)
      assert person.athlete?
    end
  end

  test "find_or_create_by_name! records a matched spelling as an alias" do
    # "Pat. Passer" parameterizes to the same slug, so strategy 1 finds the
    # existing record; the differing spelling is then kept as an alias.
    assert_no_difference "Person.count" do
      Person.find_or_create_by_name!("Pat.", "Passer")
    end

    assert_includes people(:passer).reload.aliases, "Pat. Passer"
  end

  test "find_or_create_by_name! does not duplicate an alias it already holds" do
    Person.find_or_create_by_name!("Pat.", "Passer")
    Person.find_or_create_by_name!("Pat.", "Passer")
    assert_equal 1, people(:passer).reload.aliases.count("Pat. Passer")
  end

  # The known limit of the matcher, pinned deliberately rather than assumed
  # away. A SUFFIX is not stripped by any of the three strategies, so a source
  # that adds "Jr." to a name we hold without one creates a SECOND Person. The
  # nflverse importer sidesteps this entirely by matching on cross-reference
  # IDs; anything that matches by name alone needs the alias pre-recorded (as
  # the `suffixed` fixture does) or a dedupe pass afterwards.
  test "a suffix variant is NOT matched by name alone" do
    assert_nil Person.find_by_name("Pat", "Passer Jr.")

    assert_difference "Person.count", 1 do
      Person.find_or_create_by_name!("Pat", "Passer Jr.")
    end
  end

  test "find_or_create_by_name! promotes role flags without clearing existing ones" do
    person = Person.find_or_create_by_name!("Pat", "Passer", coach: true)
    assert person.coach?, "the coach flag is added"
    assert person.athlete?, "the existing athlete flag survives"
  end

  test "athlete_profile reaches the Athlete through the slug FK" do
    assert_equal athletes(:passer), people(:passer).athlete_profile
  end

  # Sluggable rewrites the slug on EVERY save, so correcting a name silently
  # renames the row — and athletes.person_slug does not follow it. This is
  # inherited behavior from mcritchie-studio, kept for parity so the later
  # importers port unchanged. Pinned here so the sharp edge is visible rather
  # than discovered.
  test "renaming a person rewrites the slug and orphans the athlete FK" do
    person = people(:passer)
    person.update!(last_name: "Renamed")

    assert_equal "pat-renamed", person.reload.slug
    assert_nil person.athlete_profile,
      "the Athlete still points at the OLD slug — rename with care until this is reconciled"
  end
end
