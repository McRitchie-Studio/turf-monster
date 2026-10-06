require "test_helper"

# [unit] LaptopSnapshotCache's key and expiry. The key must move with every
# write the snapshot draws, must not move without one, and must carry nothing
# about the viewer (there is no viewer argument to carry). The cross-viewer
# render half is test/integration/laptop_snapshot_cache_test.rb.
class LaptopSnapshotCacheTest < ActiveSupport::TestCase
  T0 = Time.utc(2026, 10, 18, 18, 0, 0)

  Rec = Struct.new(:id, :updated_at, :created_at, keyword_init: true)
  FakeGame = Struct.new(:updated_at, :goals, keyword_init: true)

  def showcase(contest_at: T0, entry_at: T0, matchup_at: T0, game_at: T0, goals: [], message_id: 7, focus: "kc-at-buf")
    NextContest::LiveShowcase.new(
      contest: Rec.new(id: 42, updated_at: contest_at),
      games: { active: [FakeGame.new(updated_at: game_at, goals: goals)], upcoming: [], completed: [] },
      focus_slug: focus,
      matchups: [Rec.new(updated_at: matchup_at)],
      entries: [Rec.new(updated_at: entry_at), Rec.new(updated_at: T0 - 1.hour)],
      messages: [Rec.new(id: message_id, created_at: T0)]
    )
  end

  def key(sc = showcase, host: "turf.example", https: true)
    LaptopSnapshotCache.key(sc, host: host, https: https)
  end

  test "the same showcase gives the same key" do
    assert_equal key, key(showcase)
  end

  test "the key moves with every stamp the snapshot draws" do
    base = key
    later = T0 + 1.second
    {
      "contest" => showcase(contest_at: later),
      "entry score" => showcase(entry_at: later),
      "matchup" => showcase(matchup_at: later),
      "game score" => showcase(game_at: later),
      "a goal" => showcase(goals: [Rec.new(id: 1, updated_at: T0)]),
      "a chat line" => showcase(message_id: 8),
      "the featured game" => showcase(focus: "sf-at-sea")
    }.each do |what, changed|
      refute_equal base, key(changed), "#{what} must move the key"
    end
  end

  test "the host and scheme are in the key, since the render writes absolute URLs" do
    refute_equal key(host: "a.example"), key(host: "b.example")
    refute_equal key(https: true), key(https: false)
  end

  test "the key names the contest, not a viewer" do
    assert_includes key, "/42/"
    assert_match %r{\Alaptop-live-snapshot/#{LaptopSnapshotCache::VERSION}/}, key
  end

  test "an entry expires after TTL, so a write that skips updated_at still lands within a minute" do
    assert_equal 60.seconds, LaptopSnapshotCache::TTL
    store = ActiveSupport::Cache::MemoryStore.new
    calls = 0
    Rails.stub(:cache, store) do
      travel_to(T0) do
        2.times { LaptopSnapshotCache.fetch(showcase, host: "h", https: true) { calls += 1 } }
        assert_equal 1, calls, "a second hit inside the TTL is served from the cache"
      end
      travel_to(T0 + LaptopSnapshotCache::TTL + 1.second) do
        LaptopSnapshotCache.fetch(showcase, host: "h", https: true) { calls += 1 }
        assert_equal 2, calls, "past the TTL it renders again"
      end
    end
  end
end
