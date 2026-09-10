require "test_helper"

class MarketSnapshotTest < ActiveSupport::TestCase
  def valid_attrs(**overrides)
    {
      sport: "nfl",
      year: 2026,
      week: 3,
      source: "test_source",
      source_url: "https://example.test/x",
      captured_at: Time.current,
      dataset_path: "db/seeds/data/nfl/2026_expected_team_totals.csv",
      checksum: "abc123",
      row_count: 2,
      posted_count: 1,
      derived_count: 1
    }.merge(overrides)
  end

  test "valid with a full set of attributes" do
    assert MarketSnapshot.new(valid_attrs).valid?
  end

  test "week may be nil for a season-wide run" do
    assert MarketSnapshot.new(valid_attrs(week: nil)).valid?
  end

  test "rejects an out-of-range week" do
    snapshot = MarketSnapshot.new(valid_attrs(week: 19))
    assert_not snapshot.valid?
    assert_includes snapshot.errors[:week], "must be in 1..18"
  end

  test "requires provenance columns" do
    assert_not MarketSnapshot.new(valid_attrs(source: nil)).valid?
    assert_not MarketSnapshot.new(valid_attrs(checksum: nil)).valid?
    assert_not MarketSnapshot.new(valid_attrs(dataset_path: nil)).valid?
    assert_not MarketSnapshot.new(valid_attrs(captured_at: nil)).valid?
  end

  test "rejects negative counts" do
    assert_not MarketSnapshot.new(valid_attrs(row_count: -1)).valid?
  end

  test "label summarizes the run" do
    assert_equal "nfl 2026 week 3 — 2 rows (1 posted, 1 derived)",
      MarketSnapshot.new(valid_attrs).label
    assert_equal "nfl 2026 season — 2 rows (1 posted, 1 derived)",
      MarketSnapshot.new(valid_attrs(week: nil)).label
  end
end
