# frozen_string_literal: true

require "test_helper"

# THE MIGRATION'S RULE AND THE MODEL'S RULE MUST AGREE.
#
# They are two deliberately separate copies — the migration's is SQL frozen in
# time, the model's is Ruby that keeps evolving — and nothing else in the suite
# loads `up`, because the test DB is built from schema.rb. So without this,
# inverting the SQL would leave every test green while production rows go wrong.
#
# The precedent is test/models/slate_sport_year_test.rb, written after exactly
# that: a ternary inverted inside `up` backfilled 28 slates wrong and the suite
# stayed green.
#
# This asserts the ACTUAL SQL that runs, evaluated by the database, rather than
# a Ruby restatement of it — a restatement would be a third copy to drift.
class SlateSeasonTypeDriftTest < ActiveSupport::TestCase
  require Rails.root.join("db/migrate/20260904163053_add_season_type_to_slates.rb").to_s

  NAME_CORPUS = {
    "NFL 2026 Preseason Week 3" => AddSeasonTypeToSlates::PRESEASON,
    "NFL 2026 Preseason Week 4" => AddSeasonTypeToSlates::PRESEASON,
    "NFL 2026 Preseason Weeks 3-4" => AddSeasonTypeToSlates::PRESEASON,
    "NFL 2026 Week 3" => AddSeasonTypeToSlates::REGULAR,
    "NFL 2026 Weeks 1-3" => AddSeasonTypeToSlates::REGULAR,
    "NFL 2026 Week 18" => AddSeasonTypeToSlates::REGULAR,
    "World Cup 2026 Group 1" => AddSeasonTypeToSlates::REGULAR,
    "World Cup 2026 Final" => AddSeasonTypeToSlates::REGULAR,
    "Default" => AddSeasonTypeToSlates::REGULAR
  }.freeze

  # Ask the DATABASE whether the migration's predicate matches, exactly as `up`
  # asks it.
  def migration_says(name)
    matched = ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(
        ["SELECT (#{AddSeasonTypeToSlates::PRESEASON_NAME_SQL}) FROM (SELECT ?::text AS name) t", name]
      )
    )
    ActiveModel::Type::Boolean.new.cast(matched) ? AddSeasonTypeToSlates::PRESEASON : AddSeasonTypeToSlates::REGULAR
  end

  test "[unit] the migration's SQL and the model's Ruby classify every name the same" do
    checked = 0

    NAME_CORPUS.each do |name, expected|
      from_migration = migration_says(name)
      from_model = Slate.season_type_from_name(name)

      assert_equal expected, from_migration, "migration SQL misreads #{name.inspect}"
      assert_equal expected, from_model, "model rule misreads #{name.inspect}"
      checked += 1
    end

    # A corpus that silently emptied would pass every assertion above while
    # comparing nothing.
    assert_equal NAME_CORPUS.size, checked
    assert_operator checked, :>=, 9
  end

  # The scales must be the same ones `games` already speaks, or a comparison
  # between the two tables silently matches nothing.
  test "[unit] the migration and the model use ESPN's shared codes" do
    assert_equal Slate::PRESEASON_SEASON_TYPE, AddSeasonTypeToSlates::PRESEASON
    assert_equal Slate::DEFAULT_SEASON_TYPE, AddSeasonTypeToSlates::REGULAR
    assert_equal Nfl::BuildPreseasonSlate::PRESEASON, Slate::PRESEASON_SEASON_TYPE
  end
end
