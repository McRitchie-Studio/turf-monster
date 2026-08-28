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
  #
  # BUT A STRIPPER THAT REMOVES TOO MUCH IS WORSE THAN NONE, because it fails
  # SILENT: the scan still runs, still passes, and is reading nothing. The first
  # cut here was `/\/\*.*?\*\//m`, and a single unbalanced `/*` — inside a JS
  # regex literal in _alpine_factories.html.erb — paired with a genuine `*/` far
  # below it and swallowed 93% of that file (52,907 chars down to 3,477). The two
  # bare confetti zIndex values Carl found were inside the swallowed span, which
  # is exactly why the guard never saw them.
  #
  # So this is LINE-ORIENTED and fails OPEN: it drops whole-line comments and
  # trailing comments, and an unterminated opener costs one line, never the rest
  # of the file. `stripper_retains_most_of_each_file` below is the guard on the
  # guard.
  COMMENT_LINE = %r{\A\s*(?://|\*|/\*|<%#|<!--)}
  TRAILING     = %r{//.*\z}

  # ERB and HTML comments are structurally reliable — they cannot be opened
  # without being closed — so span-stripping them is always safe, however much
  # of a file they account for.
  def without_markup_comments(raw)
    raw.gsub(/<%#.*?%>/m, " ").gsub(/<!--.*?-->/m, " ")
  end

  # `/* */` is the dangerous one: a `/*` can sit inside a JS string or regex
  # literal and pair with a genuine `*/` far below it. Span-strip only when the
  # file's openers and closers BALANCE; otherwise fall back to line-oriented,
  # where a stray opener costs one line instead of the rest of the file.
  def without_block_comments(text)
    if text.scan(%r{/\*}).size == text.scan(%r{\*/}).size
      text.gsub(%r{/\*.*?\*/}m, " ")
    else
      text.each_line.reject { |l| l.match?(COMMENT_LINE) }.join
    end
  end

  def markup_of(path)
    text = without_block_comments(without_markup_comments(Pathname(path).read))
    text.each_line.map { |l| l.gsub(TRAILING, " ") }.join
  end

  # For the drift scan only: collapsing token reads keeps a fallback like
  # var(--z-docked, 100) from reading as a bare 100.
  def code_of(path)
    markup_of(path).gsub(/var\([^)]*\)/, "var()")
  end

  # THE GUARD ON THE GUARD. A stripper that eats the file it is meant to read
  # reports "clean" forever, and nothing else in this suite would notice. Any
  # file the drift scan covers must survive it substantially intact.
  # Measured across the BLOCK-COMMENT stage only, and that scoping is the point.
  # A file may legitimately be four-fifths ERB doc comment — _entry_token_badge
  # is — and `<%# %>` cannot run away, so counting it here would only teach the
  # guard to tolerate the number that matters. `/* */` is the stage that ate 93%
  # of _alpine_factories from one unbalanced opener, so that is the stage the
  # threshold watches.
  test "block-comment stripping never eats a file it is meant to scan" do
    gutted = (Dir[Rails.root.join("app/views/**/*.erb")] +
              Dir[Rails.root.join("app/assets/tailwind/**/*.css")])
             .filter_map do |path|
      before = without_markup_comments(Pathname(path).read)
      next if before.length < 2_000

      # markup_of, not without_block_comments — the ORDER is the load-bearing
      # part and only the real function has it. The stray `/*` that caused this
      # lives INSIDE an ERB comment, so stripping block comments first let it
      # pair with a genuine `*/` far below; stripping ERB first leaves the file
      # balanced (measured: 3 openers / 2 closers raw, 2 / 2 after ERB). Swap the
      # two calls and this test is what says so.
      share = markup_of(path).length.to_f / before.length
      "#{Pathname(path).relative_path_from(Rails.root)} kept #{(share * 100).round}%" if share < 0.35
    end

    assert_empty gutted,
                 "block-comment stripping is eating these files, so the drift scan " \
                 "reads almost nothing in them and passes for the wrong reason:\n  " \
                 "#{gutted.join("\n  ")}"
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

  # A LEVEL ALONE IS NOT THE FIX, and this is the assertion that says so. The
  # first cut of the lift used `position: relative`, which is enough to escape
  # `z-index: auto` and enough to pass every other test here — and it left the
  # bars exactly where they were for the reader who had scrolled. Measured on the
  # contest board at scrollY 900 with the modal open: relative put the stack at
  # top -900, off screen. Nobody makes six picks without scrolling, so that is
  # the ONLY case that matters.
  #
  # sticky pins it to top 0 from any scroll offset AND keeps its space reserved
  # in flow, so applying it on open shifts no page content — `fixed` also pins,
  # but pulls the stack out of flow and the page jumps up by its height.
  test "the lift PINS the bars, it does not merely level them" do
    rule = CSS.read[/body\.modal-open\s+\.studio-bar-stack.*?\{(.*?)\}/m]

    refute_nil rule, "the modal-open lift rule is gone"
    assert_match(/position:\s*sticky/, rule,
                 "a scrolled reader never sees a bar that only got a z-index — pin it")
    assert_match(/top:\s*0/, rule,
                 "sticky without a top offset never pins")
    refute_match(/position:\s*fixed/, rule,
                 "fixed pulls the bars out of flow and the page jumps by their height")
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

  # A DROPDOWN MUST NOT OUTRANK THE NAVBAR, and the corollary is the trap this
  # pair exists to name: anything position:fixed on the dropdown tier is
  # viewport-positioned, so it competes with the navbar directly and no tier can
  # save it. It has to be POSITIONED out of the nav band instead. The chat
  # reaction picker is exactly that case — see the clamp test below.
  test "a dropdown stays under the navbar" do
    assert_operator tiers.fetch("--z-dropdown"), :<, tiers.fetch("--z-nav"),
                    "a menu that covers the navbar is a menu that covers the way out"
  end

  # The picker is position:fixed. Its floor cannot be a bare 8px or the "above"
  # placement bottoms out inside the header band, under an opaque bg-page header
  # with no pointer-events:none — invisible AND unclickable. --nav-bottom is the
  # header's LIVE bottom edge (republished on scroll and on every header resize),
  # which is what makes it right here where --nav-h is not: --nav-h is the
  # header's HEIGHT, and the two stop agreeing the moment anything renders above
  # the header — which this change does.
  test "the fixed reaction picker is clamped out of the navbar band" do
    js = markup_of(Rails.root.join("app/views/contests/_chat_panel.html.erb"))

    assert_match(/getPropertyValue\(\s*'--nav-bottom'\s*\)/, js,
                 "the picker must read the header's live bottom edge, not guess at 8px")
    assert_match(/if\s*\(\s*top\s*<\s*minTop\s*\)/, js,
                 "the flip-below decision must use the nav-aware floor")
    refute_match(/if\s*\(\s*top\s*<\s*8\s*\)/, js,
                 "a bare 8px floor is the defect: it puts the picker under the header")
  end

  # --nav-h is the header's HEIGHT; --nav-bottom is its BOTTOM EDGE. Rendering
  # the environment bars ABOVE the header pushes it down, so --nav-h shrank by
  # the stack height (measured: 96 vs 143 desktop, 131 vs 178 mobile) while the
  # header's on-screen bottom did not move. A panel positioned at --nav-h then
  # lands 47px too high and paints over the navbar's lower strip.
  test "a side panel starts below the header, not at its height" do
    panel = markup_of(Rails.root.join("app/views/components/_sidebar_panel.html.erb"))
    style = panel[/style="top:[^"]*"/]

    refute_nil style, "the panel's top offset moved or was renamed"
    assert_includes style, "--nav-bottom",
                    "a panel must START below the header — --nav-h only SIZES to it"
    refute_match(/top:var\(--nav-h/, style,
                 "--nav-h stopped tracking the header's bottom the moment bars render above it")
  end

  # OPSEC-046. The impersonation bar carries a deliberately JS-free escape hatch
  # ("Return to <admin>", a button_to that works with no Alpine and no Turbo).
  # The environment bar is an ambient label and can scroll away; an escape hatch
  # cannot. So exactly one of the two moved out of the pinned header.
  test "the impersonation escape hatch stays pinned inside the header" do
    layout = markup_of(NAVBAR)
    header = layout.index("<header")
    stack  = layout.index("studio-bar-stack")
    imp    = layout.index(%(render "shared/impersonation_banner"))

    refute_nil imp, "the impersonation bar must still render"
    assert_operator stack, :<, header,
                    "the environment bar is the one that moves out, for the modal lift"
    assert_operator imp, :>, header,
                    "the impersonation bar must stay INSIDE the pinned header — an " \
                    "admin who scrolls must not lose the way out"
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
            Dir[Rails.root.join("app/assets/tailwind/**/*.css")] +
            # JS MODULES TOO, and this glob is why the scan needed one more
            # directory: _alpine_factories' two confetti bursts were converted
            # while an identical pair in app/javascript/solana_utils.js kept its
            # bare 9999, unseen because the scan stopped at app/views.
            Dir[Rails.root.join("app/javascript/**/*.js")]

    offenders = files.flat_map do |path|
      code  = code_of(path)
      hits  = code.scan(/z-index:\s*(\d+)/).flatten
      hits += code.scan(/\bz-\[(\d+)\]/).flatten
      # JS too. canvas-confetti takes zIndex as a NUMBER, and two celebrations
      # carried bare 9999 / 10000 inside an .erb <script> — the same magic values
      # the scale replaced in CSS, in the one place a CSS-only scan could not see.
      hits += code.scan(/\bzIndex\s*:\s*(\d+)/).flatten
      hits.map(&:to_i).select { |n| n >= 100 }
          .map { |n| "#{Pathname(path).relative_path_from(Rails.root)} → #{n}" }
    end

    assert_empty offenders,
                 "use a --z-* tier, not a bare number:\n  #{offenders.join("\n  ")}"
  end
end
