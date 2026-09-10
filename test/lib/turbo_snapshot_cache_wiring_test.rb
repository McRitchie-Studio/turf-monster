require "test_helper"

# app/javascript/turbo_snapshot_cache.js closes a Turbo ordering bug that is
# GATED ON AN ACCESSIBILITY SETTING: Turbo files its snapshot one macrotask after
# turbo:before-cache and swaps the body on an unordered animation frame, and it
# disables view transitions under prefers-reduced-motion -- which is what had been
# delaying the swap enough for the snapshot to win. Without the module, a
# reduced-motion visitor's Back on /contests/:slug re-fetches from the server and a
# signed-out cart (which lives only in the DOM) is gone.
#
# The module is only load-bearing if it actually ships, and it ships through two
# separate files. Dropping either one is silent: the e2e spec that covers the
# behavior is a browser test, so nothing else in the Ruby suite would notice.
class TurboSnapshotCacheWiringTest < ActiveSupport::TestCase
  MODULE_NAME = "turbo_snapshot_cache".freeze

  test "the snapshot-ordering module exists" do
    assert File.exist?(Rails.root.join("app/javascript/#{MODULE_NAME}.js")),
           "app/javascript/#{MODULE_NAME}.js is missing -- reduced-motion Turbo restoration is unguarded"
  end

  test "the snapshot-ordering module is pinned in the importmap" do
    pins = Rails.root.join("config/importmap.rb").read
    assert_match(/^pin ["']#{MODULE_NAME}["']/, pins,
                 "config/importmap.rb must pin #{MODULE_NAME} or the browser cannot resolve the import")
  end

  test "the snapshot-ordering module is imported by the application entrypoint" do
    entry = Rails.root.join("app/javascript/application.js").read
    assert_match(/^import ["']#{MODULE_NAME}["']/, entry,
                 "application.js must import #{MODULE_NAME}; a pin alone never executes it")
  end

  test "the module holds the render until Turbo has filed its snapshot" do
    source = Rails.root.join("app/javascript/#{MODULE_NAME}.js").read

    assert_match(/addEventListener\(\s*["']turbo:before-cache["']/, source,
                 "the module has to learn a cache write is pending from turbo:before-cache")
    assert_match(/addEventListener\(\s*["']turbo:before-render["']/, source,
                 "the module has to hold the swap at turbo:before-render")
    assert_match(/event\.preventDefault\(\)/, source,
                 "holding the swap requires preventDefault on the before-render event")
    assert_match(/setTimeout\(\s*resume\s*,\s*0\s*\)/, source,
                 "the swap must resume on a macrotask queued AFTER Turbo's own clone timer -- " \
                 "resuming synchronously, or on a microtask, restores the race")
  end
end
