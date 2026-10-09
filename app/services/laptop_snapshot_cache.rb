# Rails.cache for the /turf-monster-v2 hero laptop's snapshot
# (LaptopLiveSnapshot): the rendered HTML and its score frames, so an anonymous
# hit on the marketing page does not re-render the whole live leaderboard.
#
# A CONSTANT KEY. The laptop shows a fictional contest built from fixed,
# in-memory data (LaptopFictionalShowcase), so its render does not change with
# the date or with any row in the database: nothing about a contest is in the
# key. Bump VERSION when the snapshot's shape changes. TTL only bounds how long
# an entry written by the previous deploy's partials can outlive that deploy.
#
# ONE ENTRY FOR EVERY VIEWER, ON PURPOSE. The snapshot is rendered through a
# session-less renderer (LaptopLiveSnapshot: "SIGNED OUT BY CONSTRUCTION"), so
# it is the same bytes for a guest, a signed-in player and an admin. Nothing
# about the viewer is in the key, and nothing about the viewer can be in the
# value. test/integration/laptop_snapshot_cache_test.rb renders it signed in
# and signed out and asserts they share one entry that names neither.
#
# The host is in the key because the renderer writes absolute URLs with it.
module LaptopSnapshotCache
  TTL = 10.minutes
  VERSION = 3

  def self.fetch(host:, https:, &)
    Rails.cache.fetch(key(host: host, https: https), expires_in: TTL, &)
  end

  def self.key(host:, https:)
    ["laptop-live-snapshot", VERSION, host, https ? "https" : "http"].join("/")
  end
end
