require "test_helper"
require Rails.root.join("db/migrate/20261024120000_add_reveal_to_contests")

# [integration] The reveal migration adds its three columns with no backfill:
# an existing contest reads reveal_at nil (legacy: never revealed
# automatically), hold false and no alert. Run down then up inside the test's
# transaction, so the schema is restored by the rollback.
class AddRevealToContestsTest < ActiveSupport::TestCase
  COLUMNS = %w[reveal_at coming_soon_hold coming_soon_alerted_at].freeze

  setup do
    @migration = AddRevealToContests.new
    @migration.verbose = false
  end

  teardown { Contest.reset_column_information }

  def columns
    Contest.connection.columns(:contests).map(&:name) & COLUMNS
  end

  test "an existing contest gets reveal_at nil, hold false, no alert; up and down are rerunnable" do
    existing = Contest.create!(name: "Legacy #{SecureRandom.hex(3)}", slate: slates(:one), contest_type: "standard",
                               starts_at: 10.days.from_now, user: users(:alex), status: "open", max_entries: 29,
                               coming_soon: true)

    @migration.down
    assert_empty columns
    assert_nothing_raised { @migration.down }

    @migration.up
    assert_nothing_raised { @migration.up }
    assert_equal COLUMNS.sort, columns.sort

    row = Contest.connection.select_one(
      "SELECT reveal_at, coming_soon_hold, coming_soon_alerted_at, coming_soon FROM contests WHERE id = #{existing.id}"
    )
    assert_nil row["reveal_at"], "no backfill: a legacy row has no scheduled reveal"
    assert_equal false, row["coming_soon_hold"]
    assert_nil row["coming_soon_alerted_at"]
    assert_equal true, row["coming_soon"], "the migration leaves the flag itself alone"
  end
end
