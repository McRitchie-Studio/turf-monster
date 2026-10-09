require "test_helper"

# [integration] /turf-monster-v2 serves the hero laptop's live snapshot from
# Rails.cache (LaptopSnapshotCache), and the entry is viewer-independent: a
# signed-in render and a guest render share ONE entry, the second is not
# re-rendered, and neither page's laptop names the signed-in viewer. The key
# and TTL themselves are test/services/laptop_snapshot_cache_test.rb.
class LaptopSnapshotCacheIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    SeasonConfig.set_main_contest!(nil)
    Message.delete_all
    Selection.delete_all
    Entry.delete_all
    Contest.delete_all
    slate = Slate.create!(name: "NFL 2026 Weeks 4-6", slug: "nfl-2026-weeks-4-6-cache", sport: "nfl", starts_at: 20.days.ago)
    @contest = Contest.create!(name: "Weeks 4-6 Cache", slug: "weeks-4-6-cache", status: "open", entry_fee_cents: 1900,
                               max_entries: 29, contest_type: "standard", slate: slate, starts_at: 2.days.ago)
    game = games(:future_game)
    SlateMatchup.create!(slate: slate, team_slug: game.home_team_slug, opponent_team_slug: game.away_team_slug, game_slug: game.slug)
    @entrant = users(:sam)
    @contest.entries.create!(user: @entrant, status: :active).tap { |e| e.update_column(:score, 140.0) }
    @viewer = users(:alex)
    @viewer.update_columns(username: "viewerhandle#{@viewer.id}", email: "viewer.identity@example.com")
    @store = ActiveSupport::Cache::MemoryStore.new
  end

  def laptop_html
    css_select('[data-test="laptop-canvas"]').first.to_html
  end

  def snapshot_keys
    @store.instance_variable_get(:@data).keys.grep(/laptop-live-snapshot/)
  end

  # A cache write is a render: the block that renders only runs on a miss.
  # Counted from Active Support's own cache instrumentation.
  def counting_snapshot_writes
    writes = []
    callback = ->(*, payload) { writes << payload[:key].to_s if payload[:key].to_s.include?("laptop-live-snapshot") }
    ActiveSupport::Notifications.subscribed(callback, "cache_write.active_support") { yield }
    writes
  end

  test "a signed-in render and a guest render share one cache entry that names neither viewer" do
    signed_in = guest = nil
    writes = Rails.stub(:cache, @store) do
      counting_snapshot_writes do
        log_in_as(@viewer)
        get turf_monster_v2_path
        assert_response :success
        signed_in = laptop_html
        # The sign-in took: the page's own chrome names the viewer, so the
        # laptop not naming them below is a real check, not a guest twice.
        assert_includes response.body, @viewer.username, "signed in as the viewer"

        reset! # a fresh session: a guest
        get turf_monster_v2_path
        assert_response :success
        guest = laptop_html
      end
    end

    assert_equal 1, writes.size, "rendered once; the guest view was served from the cache"
    assert_equal 1, snapshot_keys.size, "one entry for both viewers"
    refute_includes snapshot_keys.first, @viewer.username, "the key carries no viewer"
    assert_equal signed_in, guest, "the same laptop bytes for both"
    [signed_in, guest].each do |html|
      refute_includes html, @viewer.username
      refute_includes html, @viewer.email
      refute_includes html, @entrant.username, "the laptop is fictional: no real entrant either"
    end
    cached = @store.read(snapshot_keys.first)
    refute_includes cached[:html], @viewer.username
    refute_includes cached[:html], @viewer.email
  end
end
