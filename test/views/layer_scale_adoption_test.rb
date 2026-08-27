# frozen_string_literal: true

require "test_helper"

# [component] Adoption of studio-engine's shared layer scale, and the two defects
# it was built to close.
#
# BOTH WERE VISIBLE ON ONE QA SCREENSHOT. The sign-in modal was open, and:
#
#   1. the docked "Hold to Confirm" bar painted straight over the card. It
#      carried an inline `z-index:9999`; the modal host's backdrop carried
#      `z-[120]`. Not a bug in either component — nothing anywhere said which
#      should win, and its own DESKTOP twin sat at z-40, 9,959 away.
#   2. the QA / DEV MODE bar dimmed behind that same backdrop, because it had no
#      stacking level at all AND was rendered inside the sticky <header>, which
#      carries a z-index and is therefore a stacking context. A descendant's
#      z-index is clamped inside its context, so no value on the banner could
#      ever have escaped. Moving it OUT is the fix; the level is the follow-on.
#
# The scale itself is the engine's (engine.css `-- Layer scale`), mirrored in
# application.css until the pin reaches the gem that ships it. This test pins the
# ADOPTION: the structure defect 2 needs, the value defect 1 needs, and a drift
# guard so the next bare 9999 is refused where it is written.
class LayerScaleAdoptionTest < ActionDispatch::IntegrationTest
  CSS    = Rails.root.join("app/assets/tailwind/application.css")
  NAVBAR = Rails.root.join("app/views/layouts/_navbar.html.erb")
  BOARD  = Rails.root.join("app/views/contests/_turf_totals_board.html.erb")
  HOST   = Rails.root.join("app/views/studio/modals/_host.html.erb")

  # Comments are prose, and every one of these files EXPLAINS the defect using
  # the very numbers being banned. Scanning them would make documenting the fix
  # impossible — which is the opposite of the point.
  def markup_of(path)
    Pathname(path).read
                  .gsub(%r{/\*.*?\*/}m, " ")
                  .gsub(/<%#.*?%>/m, " ")
                  .gsub(/<!--.*?-->/m, " ")
  end

  # For the drift scan only: collapsing token reads keeps a fallback like
  # var(--z-docked, 100) from reading as a bare 100.
  def code_of(path)
    markup_of(path).gsub(/var\([^)]*\)/, "var()")
  end

  # root_path redirects to the featured contest; the navbar is what is under
  # test, so land on whatever page it actually serves.
  def visit_home
    get root_path
    follow_redirect! while response.redirect?
    assert_response :success
    Nokogiri::HTML5(response.body)
  end

  def tiers
    @tiers ||= CSS.read[/^:root \{(.*?)^\}/m].to_s
                  .scan(/(--z-[a-z-]+):\s*(-?\d+);/)
                  .to_h { |name, value| [name, value.to_i] }
  end

  # ── Defect 2: the structure that makes a level reachable ──────────────

  test "the bar stack renders outside the pinned header, above it" do
    page  = visit_home
    stack = page.at_css("[data-studio-bar-stack]")
    header = page.at_css("header[data-navbar-root]")

    refute_nil stack,  "the QA / impersonation bars must render in a stack element"
    refute_nil header, "the navbar must still render"

    assert_nil stack.at_xpath("ancestor::header"),
               "the stack is inside <header>, which is sticky WITH a z-index and " \
               "therefore a stacking context — a descendant's z-index is clamped " \
               "inside it, so no level on the banner can reach over a modal"

    order = page.css("[data-studio-bar-stack], header[data-navbar-root]").map(&:name)
    assert_equal %w[div header], order,
                 "normal flow only reserves space for what comes FIRST — rendered " \
                 "after the header the bars would push content down and be overlapped"
  end

  test "the stack stays unpositioned, so the header still paints over it on scroll" do
    stack = visit_home.at_css("[data-studio-bar-stack]")
    refute_nil stack, "the QA / impersonation bars must render in a stack element"
    classes = stack["class"].to_s.split

    %w[sticky fixed absolute].each do |positioning|
      refute_includes classes, positioning,
                      "a #{positioning} stack stops reserving layout space and the " \
                      "navbar needs a measured offset again — the thing engine 0.39.0 removed"
    end
    refute classes.any? { |c| c.start_with?("z-") },
           "the stack must not outrank the pinned header while scrolling; the lift " \
           "is scoped to body.modal-open, when scroll is locked and it costs nothing"
  end

  test "the modal-open lift still finds the class the navbar emits" do
    assert_match(/body\.modal-open\s+\.studio-bar-stack/, CSS.read,
                 "application.css lost the lift rule that raises the bars over a modal")
    assert_match(/class="[^"]*\bstudio-bar-stack\b[^"]*"/, markup_of(NAVBAR),
                 "the navbar no longer EMITS studio-bar-stack, the class the lift selects")
  end

  # ── Defect 1: the docked bar stops outranking the modal ───────────────

  test "the mobile entry slip is docked, not on top of everything" do
    slip = code_of(BOARD)[/style="position:fixed;bottom:0;[^"]*"/]

    refute_nil slip, "the mobile entry slip's fixed positioning moved or was renamed"
    assert_includes slip, "z-index:var()",
                    "the slip must read a tier — a literal here is how it reached 9999"
    refute_match(/z-index:\s*\d/, slip,
                 "a bare number on the slip is the defect returning")
  end

  test "the modal host reads the modal tier" do
    assert_includes markup_of(HOST), "z-[var(--z-modal)]",
                    "the backdrop is the app blocker; it must sit on the shared tier"
  end

  test "docked, nav and drawer all stay below the modal" do
    %w[--z-docked --z-nav --z-drawer].each do |below|
      assert tiers.fetch(below) < tiers.fetch("--z-modal"),
             "#{below} must stay below --z-modal — a modal is the active task"
    end
    %w[--z-toast --z-banner].each do |above|
      assert tiers.fetch(above) > tiers.fetch("--z-modal"),
             "#{above} must stay above --z-modal or a QA session cannot reach it"
    end
  end

  # ── Drift ─────────────────────────────────────────────────────────────

  test "nothing in this app paints at a bare blocking number" do
    files = Dir[Rails.root.join("app/views/**/*.erb")] +
            Dir[Rails.root.join("app/assets/tailwind/**/*.css")]

    offenders = files.flat_map do |path|
      code  = code_of(path)
      hits  = code.scan(/z-index:\s*(\d+)/).flatten
      hits += code.scan(/\bz-\[(\d+)\]/).flatten
      hits.map(&:to_i).select { |n| n >= 100 }
          .map { |n| "#{Pathname(path).relative_path_from(Rails.root)} → #{n}" }
    end

    assert_empty offenders,
                 "use a --z-* tier, not a bare number:\n  #{offenders.join("\n  ")}"
  end
end
