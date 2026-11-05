# frozen_string_literal: true

require "test_helper"

# [unit] Turf on the engine's glass surfaces (/tasks/turf-adopts-glass-style).
#
# The engine holds the look. These pin the three things only this app can get
# wrong: it asks for the style, its own layout says so on the root (Turf has its
# own layout, so the engine's preview attribute never reaches it), and its own gear
# menu carries the structure the engine's glass rows select on. A browser proves the
# paint: e2e/glass_surfaces.spec.js.
class GlassSurfaceAdoptionTest < ActionDispatch::IntegrationTest
  test "Turf sets the glass surface and sidebar styles" do
    assert_equal :glass, Studio.surface_style
    assert_equal :glass, Studio.sidebar_style
  end

  test "the layout renders the style on the root, signed out" do
    get contests_path
    assert_response :success
    assert_match(/<html lang="en" data-surface-style="glass">/, response.body)
  end

  test "the root says nothing when the app asks for no style" do
    Studio.stub :surface_style, :default do
      get contests_path
      assert_response :success
      assert_match(/<html lang="en">/, response.body)
    end
  end

  test "both gear panels float on the engine's glass, with rows in groups and Log out in the foot" do
    log_in_as_onchain(users(:sam))
    get contests_path
    assert_response :success
    body = response.body

    assert_equal 2, body.scan("data-sidebar-glass-shell").size, "the desktop and phone panels"
    assert_equal 2, body.scan(/<div class="border-t border-subtle" data-sidebar-glass-foot>/).size

    nav = body[/<nav [^>]*aria-label="Settings links".*?<\/nav>/m]
    assert nav, "the gear menu's nav"
    assert_includes nav, 'role="group" aria-label="Account"',
      "engine.css selects rows as nav > [role=group] > a, so a bare row gets no glass spacing"
    assert_includes nav, "Refresh Wallet"
    refute_includes nav, "/logout", "Log out is the panel's foot, as on the hub's link sidebar"

    foot = body[/data-sidebar-glass-foot>.*?<\/div>/m]
    assert_includes foot, 'href="/logout"'
    assert_includes foot, 'data-studio-action="session-wipe#wipe"', "the foot keeps the wipe"
  end

  test "the gear menu falls back to the plain panel with no style set" do
    Studio.stub :sidebar_style, :default do
      log_in_as_onchain(users(:sam))
      get contests_path
      assert_response :success
      refute_includes response.body, "data-sidebar-glass-shell"
      assert_includes response.body, "data-sidebar-glass-foot", "the foot still holds Log out"
    end
  end

  test "Turf's CSS owns no blur of its own for glass, and no not-query around one" do
    css = Rails.root.join("app/assets/tailwind/application.css").read
    refute_match(/@media\s+not\s*\(prefers-reduced-transparency/, css,
      "a browser that does not know the feature answers false, so Safari and Firefox would lose the blur")
    refute_match(/\[data-sidebar-glass[^{]*\{[^}]*backdrop-filter/, css, "the engine's shell holds the blur")
    refute_match(/\.nav-shell[^{]*\{[^}]*backdrop-filter/, css, "the engine's glass rule blurs the navbar")
  end

  test "a team card takes the card fill, so its selected tones still win" do
    pair = Rails.root.join("app/views/contests/_matchup_game_pair.html.erb").read
    assert_includes pair, "tm-team-card"
    refute_match(/min-w-0 bg-surface/, pair, "a solid team card is a patch on a glass board")

    css = Rails.root.join("app/assets/tailwind/application.css").read
    assert_match(/@utility tm-team-card \{\s*background-color: var\(--surface-card-fill, var\(--color-surface\)\);/, css)
  end
end
