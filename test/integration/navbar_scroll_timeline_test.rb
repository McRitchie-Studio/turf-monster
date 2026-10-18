require "test_helper"

# [component] Turf's forked navbar opts into studio-engine's scroll-driven
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
    %w[data-nav-timeline data-pin data-studio-controller].each do |attr|
      refute header.key?(attr), "a preview header carries no #{attr}: /admin/navbar repeats it"
    end
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

  test "the in-header bars move down by the band on the header's own timeline" do
    rule = CSS[/\.nav-shell\[data-nav-timeline\] > \[data-nav-header-bars\] \{[^}]*\}/]
    assert rule, "application.css carries the in-header bars' timeline rule"
    assert_includes rule, "animation-timeline: scroll(root block)"
    assert_includes rule, "animation-range: var(--nav-start, 0px) calc(var(--nav-start, 0px) + var(--nav-band))",
                    "the same range the engine scrolls the band away over, or the bars drift"
    assert_match(/@keyframes turf-nav-header-bars \{ to \{ transform: translateY\(var\(--nav-band\)\); \} \}/, CSS)
    assert_match(/animation: turf-nav-header-bars linear both/, CSS,
                 "linear, as the sticky header's own travel is linear in the scroll")
  end

  test "fixed readers of the header edge follow it on the timeline" do
    sidebar = File.read(Rails.root.join("app/views/components/_sidebar_panel.html.erb"))
    assert_match(/^\s*data-pin-edge$/, sidebar, "the side panels carry data-pin-edge")

    chat = File.read(Rails.root.join("app/views/contests/_chat_panel.html.erb"))
    assert_includes chat, "window.studioPinnedStack", "the reaction picker reads the stack live"
  end

  # /tasks/turf-navbar-avatar-table-header. The forked account carries neither
  # engine hook ([data-nav-account], [data-nav-tools]), so on the timeline it
  # kept full size in the compact bar. It carries Turf's own two, and the
  # stylesheet scales both on the engine's timeline and range.
  test "the account column and avatar carry the hooks the timeline scales, and no engine account hook" do
    log_in_as(users(:alex))
    get contests_path
    assert_response :success
    assert_select "#{HEADER} .user-nav-col [data-turf-nav-column]", 1
    assert_select "#{HEADER} .user-nav-col [data-turf-nav-avatar] [data-profile-image-toggle]", 1
    assert_select "#{HEADER} [data-nav-account], #{HEADER} [data-nav-tools]", 0,
                  "the engine hooks would also restyle the icon rail and its gaps"
  end

  test "the account scales on the header's timeline: avatar 40 to 32 from its right edge, the column by 7/8" do
    %w[data-turf-nav-avatar data-turf-nav-column].each do |hook|
      assert_match(/\.nav-shell\[data-nav-timeline\] \[#{hook}\][^{]*\{[^}]*animation-timeline: scroll\(root block\);[^}]*animation-range: var\(--nav-start, 0px\) calc\(var\(--nav-start, 0px\) \+ var\(--nav-ramp\)\);[^}]*transform-origin: right center;/m,
                   CSS, "[#{hook}] runs on the engine's timeline and ramp, from its right edge")
    end
    assert_match(/--turf-nav-avatar: calc\(2\.5rem - 0\.5rem \* var\(--nav-p, 0\)\);/, CSS,
                 "40px at rest and 32px at --nav-p 1, which is how the controller measures the compact bar")
    assert_match(/--turf-nav-avatar-scale: 0\.8;/, CSS)
    assert_match(/@keyframes turf-nav-avatar \{ to \{ transform: scale\(var\(--turf-nav-avatar-scale, 1\)\); \} \}/, CSS)
    assert_match(/@keyframes turf-nav-column \{\s*to \{ transform: translateX\(var\(--turf-nav-avatar-shrink, 0px\)\) scale\(var\(--turf-nav-column-scale, 1\)\); \}\s*\}/, CSS,
                 "the column slides right by what the avatar gave up, so the gap between them holds")
  end

  test "the nav row stops at the page container, so the avatar sits on the content's right edge" do
    assert_match(/\.nav-shell > \.nav-row \{ max-width: 80rem; margin-inline: auto; \}/, CSS,
                 "80rem is the max-w-7xl the pages lay out in; the hub carries the same rule")
  end
end
