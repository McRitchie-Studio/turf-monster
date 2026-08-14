# frozen_string_literal: true

require "test_helper"

# [unit] The installed copy of the engine's standard-profile migration must REFUSE
# to reverse.
#
# This asserts the PROPERTY, not the spelling. The engine owns the reasoning and
# its own test; what this app needs pinned is that the copy sitting in db/migrate
# here actually protects THIS database.
#
# Why a consumer-side test at all, when the engine already has one: engine
# migrations are install-COPIED (`bin/rails studio_engine:install:migrations`),
# not referenced. This app holds a FORK. `bin/rails db:rollback` runs the file
# below, never the gem's — so a gem bump cannot deliver this guard, and the
# engine's green suite says nothing about this app's exposure.
#
# What it protects, measured before the fix on a host owning first_name with data
# in it: `up` then `down` left the column GONE and the row's value destroyed, with
# no error raised. turf-monster owned `first_name` AND `birth_year` before the
# engine ever shipped this migration, so both were in that blast radius.
class StandardProfileRollbackGuardTest < ActiveSupport::TestCase
  MIGRATION = Rails.root.glob("db/migrate/*_add_standard_user_profile_columns.studio_engine.rb").freeze

  test "exactly one copy of the engine profile migration is installed" do
    # Two copies under different timestamps share a class name, and Rails groups
    # migrations by NAME — a duplicate raises DuplicateMigrationNameError on every
    # db:migrate, including the release phase. This app has already been bitten.
    assert_equal 1, MIGRATION.length,
      "expected exactly one installed copy, found: #{MIGRATION.map(&:basename).map(&:to_s).inspect}"
  end

  test "the installed migration refuses to reverse instead of dropping columns" do
    require MIGRATION.sole.to_s

    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      AddStandardUserProfileColumns.new.migrate(:down)
    end
    assert_match(/cannot be reversed safely/, error.message)
  end

  test "a refused rollback leaves this app's user columns intact" do
    require MIGRATION.sole.to_s

    before = User.columns_hash.keys.sort
    assert_includes before, "first_name", "precondition: turf owns first_name"
    assert_includes before, "birth_year", "precondition: turf owns birth_year"

    assert_raises(ActiveRecord::IrreversibleMigration) do
      AddStandardUserProfileColumns.new.migrate(:down)
    end

    User.reset_column_information
    assert_equal before, User.columns_hash.keys.sort, "a refused rollback must drop nothing"
  end
end
