require "test_helper"

# [component] the importmap markup that actually ships app/javascript/turbo_snapshot_cache.js.
#
# That module holds Turbo's page swap for one macrotask so Turbo's snapshot clone
# -- deferred one tick past turbo:before-cache, and taken from the LIVE document --
# is filed before the DOM it describes is replaced. Turbo disables view transitions
# under prefers-reduced-motion, and it was their ~30ms of setup that had been
# winning that race by accident; without them a signed-out visitor's Back re-fetches
# from the server and their cart, which lives only in the DOM, comes back empty.
#
# What a component tier can and cannot prove: it CANNOT prove the ordering holds --
# that needs a real restoration visit, which is
# e2e/cart_survives_turbo_restore.spec.js's job. What it CAN prove is that the
# module is REACHABLE from the rendered page. An importmap module ships through two
# independent files (config/importmap.rb pins it, application.js imports it), and a
# pin that never resolves is a 404 in the browser console and a silently disarmed
# fix -- with nothing in the Ruby suite failing.
class TurboSnapshotCacheImportmapTest < ActionView::TestCase
  MODULE_NAME = "turbo_snapshot_cache".freeze

  test "the rendered importmap resolves the snapshot-ordering module" do
    html = ApplicationController.helpers.javascript_importmap_tags

    assert_includes html, MODULE_NAME,
                    "the rendered importmap must carry #{MODULE_NAME} or the browser cannot resolve the import"
  end

  test "the resolved path points at a digested asset that exists" do
    entry = Rails.application.importmap.packages[MODULE_NAME]
    refute_nil entry, "#{MODULE_NAME} is not pinned in config/importmap.rb"

    resolved = Rails.application.importmap
                    .to_json(resolver: ApplicationController.helpers)
    assert_match(/"#{MODULE_NAME}":\s*"[^"]+"/, resolved,
                 "#{MODULE_NAME} must resolve to a real asset path; an unresolvable pin 404s in the browser")
  end

  test "the entrypoint the importmap preloads actually imports the module" do
    entry = Rails.root.join("app/javascript/application.js").read

    assert_match(/^import ["']#{MODULE_NAME}["']/, entry,
                 "application.js must import #{MODULE_NAME}; a pin alone is never executed")
  end
end
