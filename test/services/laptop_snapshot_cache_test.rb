require "test_helper"

# [unit] LaptopSnapshotCache's key and expiry. The laptop's contest is
# fictional and fixed (LaptopFictionalShowcase), so the key is a constant per
# host and scheme: nothing about a contest, a date or a viewer is in it. The
# cross-viewer render half is test/integration/laptop_snapshot_cache_test.rb.
class LaptopSnapshotCacheTest < ActiveSupport::TestCase
  test "the key is the version, the host and the scheme, and nothing else" do
    assert_equal "laptop-live-snapshot/#{LaptopSnapshotCache::VERSION}/turf.example/https",
                 LaptopSnapshotCache.key(host: "turf.example", https: true)
    refute_equal LaptopSnapshotCache.key(host: "a", https: true), LaptopSnapshotCache.key(host: "b", https: true)
    refute_equal LaptopSnapshotCache.key(host: "a", https: true), LaptopSnapshotCache.key(host: "a", https: false)
  end

  test "the key does not move with the date" do
    a = travel_to(Time.utc(2026, 10, 9)) { LaptopSnapshotCache.key(host: "h", https: true) }
    b = travel_to(Time.utc(2026, 12, 25)) { LaptopSnapshotCache.key(host: "h", https: true) }
    assert_equal a, b
  end

  test "a hit is served from the store until the TTL" do
    store = ActiveSupport::Cache::MemoryStore.new
    calls = 0
    Rails.stub(:cache, store) do
      travel_to(Time.utc(2026, 10, 9, 18)) do
        2.times { LaptopSnapshotCache.fetch(host: "h", https: true) { calls += 1 } }
        assert_equal 1, calls
      end
      travel_to(Time.utc(2026, 10, 9, 18) + LaptopSnapshotCache::TTL + 1.second) do
        LaptopSnapshotCache.fetch(host: "h", https: true) { calls += 1 }
      end
    end
    assert_equal 2, calls, "re-rendered once the entry expired"
  end
end
