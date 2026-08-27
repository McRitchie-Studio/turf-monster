require "test_helper"

# Component tier for task smooth-mobile-navbar-collapse.
#
# The bug: the navbar collapse was a STEP (Alpine flipped `scrolled` at
# scrollY > 60) fed into TIME-BASED transitions (`transition-all
# duration-300` on padding, logo width/height and three font sizes). The
# finger set the step; an ease curve owned everything after it. Measured on
# 2026-08-27 at 390x844 against this worktree: the header went 178px -> 139px,
# and 232ms of that 39px of document reflow landed AFTER the scroll had
# stopped — plus a 1px reverse twitch (178 -> 179 -> shrink) in the frame the
# class flipped, because a discrete `text-3xl` -> `text-xl` swap collided with
# the stylesheet's own `transition: font-size`.
#
# The fix makes collapse progress a CONTINUOUS function of scroll position:
# one `--nav-p` (0..1) written once per animation frame, every collapsing
# dimension a calc() off it, and no time-based transition anywhere on the
# path. These tests pin that contract from the component side — markup emits
# the hooks, the stylesheet drives them off --nav-p, and the old step
# machinery cannot come back without going red here.
class NavbarCollapseComponentTest < ActionDispatch::IntegrationTest
  CSS = File.read(Rails.root.join("app/assets/tailwind/application.css"))
  NAVBAR = File.read(Rails.root.join("app/views/layouts/_navbar.html.erb"))
  USER_NAV = File.read(Rails.root.join("app/views/components/_user_nav.html.erb"))
  FACTORIES = File.read(Rails.root.join("app/views/shared/_alpine_factories.html.erb"))

  # Every dimension the collapse moves, with the calc() the stylesheet must
  # interpolate it through. If one of these regresses to a static value or a
  # class swap, the collapse stops tracking the finger for that dimension.
  DRIVEN_HOOKS = %w[--nav-pad --nav-logo-size --nav-title-size --nav-title-lead-size --nav-balance-size --nav-username-size].freeze

  test "the collapse is a continuous function of scroll, not a 60px step" do
    assert_match(/@property\s+--nav-p\b/, CSS,
      "--nav-p must be a registered custom property so calc() has a typed <number> and a 0 fallback")
    assert_match(/syntax:\s*"<number>"/, CSS, "--nav-p must be registered as <number>")

    assert_includes NAVBAR, 'x-data="navCollapse()"',
      "the header must own the scroll-linked collapse component"
    assert_match(/window\.navCollapse\s*=\s*function/, FACTORIES,
      "navCollapse must be defined in the inline factory script (Alpine reads x-data before importmap modules run)")

    refute_match(/@scroll\.window/, NAVBAR,
      "the raw per-event @scroll.window handler is what ran unthrottled; navCollapse binds a passive rAF-coalesced listener instead")
    refute_match(/scrollY > 60/, NAVBAR,
      "the 60px collapse step is replaced by a --nav-ramp interpolation")
  end

  test "navCollapse coalesces scroll into one frame and listens passively" do
    assert_match(/requestAnimationFrame/, FACTORIES[/window\.navCollapse[\s\S]*?\n  \};/] || "",
      "navCollapse must coalesce scroll events into a single animation frame")
    assert_match(/addEventListener\("scroll",[^)]*\{\s*passive:\s*true\s*\}/, FACTORIES,
      "the scroll listener must be passive so it never blocks the compositor")
    assert_match(/prefers-reduced-motion/, FACTORIES,
      "reduced motion must snap --nav-p to 0/1 rather than resize type every frame")
  end

  test "no collapsing dimension is animated on a clock" do
    # transition-all catches padding, width/height and font-size — every one of
    # them a layout property on a sticky header that sits above the whole
    # document. The header keeps transition-shadow (paint only, moves nothing).
    refute_includes NAVBAR, "transition-all duration-300",
      "the navbar's collapsing elements must not carry a time-based transition"
    assert_includes NAVBAR, "transition-shadow",
      "the shadow may still fade on a clock — it paints and never reflows"

    %w[--nav-pad --nav-logo-size --nav-title-size].each do |hook|
      assert_match(/#{Regexp.escape(hook)}:\s*calc\([^;]*var\(--nav-p\)/, CSS,
        "#{hook} must interpolate off --nav-p")
    end

    refute_match(/^\s*\.is-scrolled\s+\.nav-(title|logo)/, CSS,
      "the .is-scrolled size overrides are replaced by --nav-p interpolation")
    refute_match(/transition:\s*font-size/, CSS,
      "font-size transitions produced the 1px reverse twitch at the threshold")
  end

  test "the rendered navbar carries every --nav-p driven hook" do
    log_in_as(users(:alex))
    get contests_path
    assert_response :success

    doc = Nokogiri::HTML5.parse(response.body)
    header = doc.at_css("[data-navbar-root]")
    assert header, "navbar must render"

    assert header["class"].split.include?("nav-shell"),
      "the header is the --nav-p scope root"
    assert doc.at_css(".nav-shell .nav-row"), "the collapsing row needs its own hook"
    assert doc.at_css(".nav-shell .nav-logo"), "logo hook"
    assert doc.at_css(".nav-shell .nav-title"), "title hook"

    DRIVEN_HOOKS.each do |hook|
      assert_match(/#{Regexp.escape(hook)}:/, CSS, "stylesheet must define #{hook}")
    end
  end

  test "the size bindings left Alpine's per-scroll reactive path" do
    refute_match(/x-bind:class="scrolled \?/, NAVBAR,
      "the balance size must come from --nav-p, not a reactive class swap")
    refute_match(/x-bind:class="scrolled \?/, USER_NAV,
      "the username size must come from --nav-p, not a reactive class swap")
    assert_includes USER_NAV, "nav-username", "username needs the --nav-p sized hook"
    assert_includes NAVBAR, "nav-balance", "balance needs the --nav-p sized hook"
  end
end
