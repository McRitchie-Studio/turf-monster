require "test_helper"

# [unit] GearSidebarPanels (lib/gear_sidebar_panels.rb) is the ONE home of the
# gear sidebar's two panel ids (/tasks/turf-readopts-engine-navbar, folding in
# the engine-adoption-loose-ends follow-up "engine-owned DOM ids as one
# constant", from this app's side). Before it, the ids were string literals in
# five files, and a rename in one left the others pointing at nothing with no
# error: a dead aria-controls is valid markup.
#
# Two drifts are pinned here: every Turf surface that names the panels reads
# the constant, and the constant never names the engine's own link sidebar,
# whose script claims any trigger that does (studio/link_sidebar).
class GearSidebarPanelsTest < ActiveSupport::TestCase
  ENGINE_LINK_SIDEBAR_JS = Studio::Engine.root.join("app/javascript/studio/link_sidebar.js")

  # Every file that opens, closes or finds the gear sidebar by id.
  READERS = %w[
    app/views/components/_gear_sidebar.html.erb
    app/views/components/_gear_sidebar_trigger.html.erb
    app/views/components/_entry_token_badge.html.erb
    app/views/layouts/application.html.erb
    app/views/test/quest_walk.html.erb
    config/initializers/studio.rb
  ].freeze

  test "the constant is the two panels, desktop then phone" do
    assert_equal %w[gear-sidebar gear-sidebar-mobile], GearSidebarPanels::IDS
    assert_equal "gear-sidebar gear-sidebar-mobile", GearSidebarPanels::CONTROLS
    assert GearSidebarPanels::IDS.frozen?
  end

  test "every surface that names the panels reads the constant, not a literal" do
    READERS.each do |path|
      src = Rails.root.join(path).read.gsub(/<%#.*?%>/m, " ").gsub(/^\s*#.*$/, " ")
      assert_includes src, "GearSidebarPanels::", "#{path} no longer reads GearSidebarPanels"
      GearSidebarPanels::IDS.each do |id|
        refute_match(/["'#=]#{Regexp.escape(id)}["'\]\s,)]/, src, "#{path} spells #{id} as a literal again")
      end
    end
  end

  # The engine refuses its own ids in navbar_account_sidebar's controls at
  # assignment (0.114.0). This holds the same line from the engine's SOURCE OF
  # TRUTH for those ids, so a renamed engine panel cannot collide unseen.
  test "the panels never take the engine link sidebar's ids" do
    engine_ids = ENGINE_LINK_SIDEBAR_JS.read[/export const LINK_SIDEBAR_PANELS = "([^"]+)"/, 1]
    assert engine_ids, "studio/link_sidebar.js no longer exports LINK_SIDEBAR_PANELS; re-derive this guard"
    engine_ids = engine_ids.scan(/#([\w-]+)/).flatten
    assert_equal %w[studio-link-sidebar studio-link-sidebar-mobile], engine_ids

    assert_empty GearSidebarPanels::IDS & engine_ids
    GearSidebarPanels::IDS.each do |id|
      refute engine_ids.any? { |engine_id| GearSidebarPanels::CONTROLS.split.include?(engine_id) }, id
    end
  end

  test "the engine account button is configured with the constant" do
    config = Studio.navbar_account_sidebar
    assert_equal "gearOpen", config[:flag]
    assert_equal GearSidebarPanels::IDS, Array(config[:controls])
  end
end
