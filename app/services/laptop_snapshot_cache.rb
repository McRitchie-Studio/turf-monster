# Rails.cache for the /turf-monster-v2 hero laptop's live snapshot
# (LaptopLiveSnapshot): the rendered HTML and its score frames, so an anonymous
# hit on the marketing page does not re-render the whole live leaderboard.
#
# ONE ENTRY FOR EVERY VIEWER, ON PURPOSE. The snapshot is rendered through a
# session-less renderer (LaptopLiveSnapshot: "SIGNED OUT BY CONSTRUCTION"), so
# it is the same bytes for a guest, a signed-in player and an admin. Nothing
# about the viewer is in the key, and nothing about the viewer can be in the
# value. If the snapshot ever starts reading the viewer, this cache would serve
# one person's page to everyone: test/integration/laptop_snapshot_cache_test.rb
# renders it signed in and signed out and asserts they share one entry that
# names neither.
#
# FRESH WITHIN A MINUTE. The key moves with every write the snapshot draws: the
# contest row, its entries (scores and ranks), its matchups, its games (scores,
# clock, status) and their goals, and the chat's system lines. Some writes
# move no stamp here: a score writer that skips updated_at (update_column,
# update_all), a reaction on a chat line, and a game turning from upcoming to
# active on the clock alone. So the entry also expires after TTL. The stamps are read from the showcase NextContest
# already loaded for the page: computing the key issues no query.
#
# The host is in the key because the renderer writes absolute URLs with it.
module LaptopSnapshotCache
  TTL = 60.seconds
  # Bump to drop every entry at once when the snapshot's shape changes.
  VERSION = 2

  def self.fetch(showcase, host:, https:, &)
    Rails.cache.fetch(key(showcase, host: host, https: https), expires_in: TTL, &)
  end

  def self.key(showcase, host:, https:)
    contest = showcase.contest
    games = showcase.games.values.flatten
    [
      "laptop-live-snapshot", VERSION, host, https ? "https" : "http",
      contest.id, stamp(contest.updated_at), showcase.focus_slug,
      latest(showcase.entries.map(&:updated_at)),
      latest(showcase.matchups.map(&:updated_at)),
      latest(games.map(&:updated_at)),
      latest(games.flat_map { |game| game.goals.map(&:updated_at) }),
      games.sum { |game| game.goals.size },
      latest(showcase.messages.map(&:created_at)),
      showcase.messages.map(&:id).max.to_i
    ].join("/")
  end

  def self.latest(times)
    stamp(times.compact.max)
  end

  def self.stamp(time)
    time ? time.utc.to_fs(:usec) : "-"
  end
  private_class_method :latest, :stamp
end
