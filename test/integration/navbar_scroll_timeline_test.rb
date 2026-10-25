require "test_helper"

# [component] Turf's navbar (studio-engine's own layouts/_navbar since
# /tasks/turf-readopts-engine-navbar) opts into studio-engine's scroll-driven
# collapse (config.navbar_scroll_timeline, engine 0.111.1;
# /tasks/turf-engine-navbar-timeline). The collapse itself is computed style on
# a scroll timeline, settled in a browser (e2e/navbar_scroll_timeline.spec.js);
# what a page can show is that the header opted in, still runs the engine's
# controller (which drives the --nav-p collapse on a phone), joined the pinned
# stack, and kept its in-header bars where the timeline CSS can carry them.
class NavbarScrollTimelineTest < ActionDispatch::IntegrationTest
  CSS = File.read(Rails.root.join("app/assets/tailwind/application.css"))
  HEADER = "header.nav-shell[data-navbar-root][data-pin=nav][data-nav-timeline][data-studio-controller=nav-collapse]".freeze

  test "the header opts into the scroll-driven collapse, signed out and signed in" do
    assert Studio.navbar_scroll_timeline, "config/initializers/studio.rb turns the timeline on"

    get contests_path
    assert_response :success
    assert_select HEADER, 1

    log_in_as(users(:alex))
    get contests_path
    assert_select HEADER, 1
    assert_select "header[data-pin]", 1, "the page's header is the pinned stack's only nav layer"
  end

  test "the scroll_timeline local turns the opt-in off for one render, and a preview never carries it" do
    html = ApplicationController.render(partial: "layouts/navbar",
                                        locals: { show_logged_in: false, scroll_timeline: false })
    header = Nokogiri::HTML5.fragment(html).at_css("header")
    refute header.key?("data-nav-timeline"), "scroll_timeline: false renders the --nav-p header"
    assert header.key?("data-pin")

    html = ApplicationController.render(partial: "layouts/navbar",
                                        locals: { show_logged_in: false, preview: true })
    header = Nokogiri::HTML5.fragment(html).at_css("header")
    %w[data-nav-timeline data-studio-controller].each do |attr|
      refute header.key?(attr), "a preview header carries no #{attr}: /admin/navbar repeats it"
    end
  end

  # studio-engine 0.111.3 slides [data-nav-links] left by --nav-brand-shrink so
  # the desktop links keep their gap to the scaled logo (/tasks/turf-nav-links-follow).
  # The hook rides only on the timeline header, as data-nav-timeline does.
  test "the timeline header's desktop nav carries data-nav-links, signed out and signed in" do
    get contests_path
    assert_select "#{HEADER} nav[data-nav-links]", 1
    assert_select "#{HEADER} nav[data-nav-links] a[href=?]", contests_path, 1,
                  "the hook sits on the nav that holds Contests, the links beside the brand"

    log_in_as(users(:alex))
    get contests_path
    assert_select "#{HEADER} nav[data-nav-links]", 1
    assert_select "[data-nav-links]", 1, "one links layer: the drawer and preview copies carry none"
  end

  test "a scroll_timeline: false header and a preview header carry no data-nav-links" do
    [{ scroll_timeline: false }, { preview: true }].each do |extra|
      html = ApplicationController.render(partial: "layouts/navbar",
                                          locals: { show_logged_in: false }.merge(extra))
      fragment = Nokogiri::HTML5.fragment(html)
      assert fragment.at_css("nav.md\\:flex"), "the desktop nav still renders (#{extra})"
      assert_nil fragment.at_css("[data-nav-links]"), "#{extra} renders no data-nav-links"
      assert_includes html, '<nav class="hidden md:flex items-center gap-4" aria-label="Main">',
                      "#{extra} renders the engine's desktop nav opening tag, hook-free"
    end
  end

  test "studio-engine slides the links on the brand's timeline (0.111.3 floor)" do
    assert Gem::Version.new(Studio::VERSION) >= Gem::Version.new("0.111.3"),
           "--nav-brand-shrink and the [data-nav-links] keyframes first ship in 0.111.3"
    engine_css = File.read(Studio::Engine.root.join("app/assets/tailwind/studio_engine/engine.css"))
    assert_match(/\[data-nav-links\] \{ animation-name: nav-tl-links; \}/, engine_css)
    assert_match(/@keyframes nav-tl-links \{ to \{ transform: translateX\(calc\(-1 \* var\(--nav-brand-shrink, 0px\)\)\); \} \}/, engine_css)
    refute_match(/\[data-nav-links\]/, CSS, "Turf adds no transform of its own to the links layer")
  end

  test "an impersonating admin's bar stays inside the header, in the band the timeline carries down" do
    admin = users(:alex)
    player = users(:jordan)
    [admin, player].each { |u| u.update_column(:slug, u.send(:name_slug)) }
    log_in_as(admin)
    post admin_impersonate_path(player.slug)

    get contests_path
    assert_response :success
    assert_select "#{HEADER} > [data-nav-header-bars]", 1 do
      assert_select "form[action=?]", admin_stop_impersonating_path
    end
  end

  test "a frozen account's bar stays inside the header too, and a good account renders no bar wrapper" do
    user = users(:jordan)
    log_in_as(user)
    get contests_path
    assert_select "[data-nav-header-bars]", 0

    user.freeze!(reason: "test", source: "console")
    get contests_path
    assert_select "#{HEADER} > [data-nav-header-bars] [data-frozen-banner]", 1
  end

  # studio-engine lifted this rule from Turf (0.114.0, engine.css THE IN-HEADER
  # BARS), so the bars ride the engine's copy and Turf keeps none of its own.
  test "the in-header bars move down by the band on the engine's timeline rule" do
    engine_css = File.read(Studio::Engine.root.join("app/assets/tailwind/studio_engine/engine.css"))
    rule = engine_css[/\.nav-shell\[data-nav-timeline\] > \[data-nav-header-bars\] \{[^}]*\}/]
    assert rule, "engine.css carries the in-header bars' timeline rule"
    assert_includes rule, "animation-timeline: scroll(root block)"
    assert_includes rule, "animation-range: var(--nav-start, 0px) calc(var(--nav-start, 0px) + var(--nav-band))",
                    "the same range the engine scrolls the band away over, or the bars drift"
    assert_includes rule, "animation: nav-tl-header-bars linear both"
    refute_match(/turf-nav-header-bars/, CSS, "no second copy: two animations on one element, one wins by order")
  end

  test "fixed readers of the header edge follow it on the timeline" do
    sidebar = File.read(Studio::Engine.root.join("app/views/components/_sidebar_panel.html.erb"))
    assert_match(/^\s*data-pin-edge$/, sidebar, "the side panels carry data-pin-edge")

    chat = File.read(Rails.root.join("app/views/contests/_chat_panel.html.erb"))
    assert_includes chat, "window.studioPinnedStack", "the reaction picker reads the stack live"
  end

  # /tasks/turf-navbar-avatar-table-header, on the engine user nav since
  # /tasks/turf-readopts-engine-navbar. The account is the engine's: the icon
  # column is [data-nav-tools], the name and avatar one [data-nav-account]
  # button that opens the gear sidebar, and the ✨ badge its sibling seat. The
  # engine scales all three on its own timeline (nav-tl-tools, nav-tl-name,
  # nav-tl-avatar) by what nav-collapse measures, so Turf adds no keyframes.
  test "the account is the engine's, with the hooks its timeline scales" do
    log_in_as(users(:alex))
    get contests_path
    assert_response :success
    assert_select "#{HEADER} .user-nav-col [data-nav-tools][data-nav-rows='2']", 1
    assert_select "#{HEADER} .user-nav-col button[data-nav-account][data-profile-image-toggle][aria-controls=?]",
                  GearSidebarPanels::CONTROLS, 1
    assert_select "#{HEADER} .user-nav-col [data-nav-account] + [data-nav-avatar-badge] [data-free-entry-badge]", 1
    assert_select "#{HEADER} [data-turf-nav-column], #{HEADER} [data-turf-nav-avatar]", 0
    refute_match(/turf-nav-avatar|turf-nav-column/, CSS, "the engine's keyframes scale the account now")
  end

  # The engine sizes a ONE-row nav's avatar 40 -> 32 on --nav-avatar and keeps a
  # two-row nav's at 2rem. Turf's nav is two rows (the seeds bar) and keeps the
  # hub's 40px, by the engine's own --nav-avatar, and the badge seat tracks it.
  test "from 768px the two-row account keeps the hub's 40px avatar on the engine's --nav-avatar" do
    assert_match(/\.nav-shell \[data-nav-account\] > \[aria-hidden\] > \* \{\s*width: var\(--nav-avatar\);\s*height: var\(--nav-avatar\);/, CSS)
    assert_match(/\.nav-shell \[data-nav-account\] \+ \[data-nav-avatar-badge\] \{\s*width: var\(--nav-avatar\);\s*height: var\(--nav-avatar\);/, CSS)
    engine_css = File.read(Studio::Engine.root.join("app/assets/tailwind/studio_engine/engine.css"))
    assert_match(/--nav-avatar: calc\(2\.5rem - 0\.5rem \* var\(--nav-p, 0\)\);/, engine_css,
                 "40px at rest and 32px at --nav-p 1, which is how the controller measures the compact bar")
  end

  test "the nav row stops at the page container, so the avatar sits on the content's right edge" do
    assert_match(/\.nav-shell > \.nav-row \{ max-width: 80rem; margin-inline: auto; \}/, CSS,
                 "80rem is the max-w-7xl the pages lay out in; the hub carries the same rule")
  end
end
