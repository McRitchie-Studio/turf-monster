require "test_helper"

# [component] The forked header's PHONE WIDTH contract — the markup chain and
# the two width caps that let layouts/_navbar shrink instead of spilling.
#
# WHAT THE DEFECT WAS, because it is not the obvious one. The header row is two
# columns: `flex-1` on the left (logo + wordmark) and a `flex-shrink-0` column
# on the right (balance, username, seeds bar, avatar). The right column's phone
# step was a CONSTANT 14rem = 224px, which is 57% of a 390px screen, on an item
# that refuses to shrink. That left the left column 166px at 390px and 96px at
# 320px for 32px of padding, a 48px logo, its gap and the app's name — and
# because every flex item defaults to `min-width: auto`, the name could not
# truncate either. So it drew OUTSIDE its own column, across the gutter, on top
# of the seeds bar and the wallet address beside it.
#
# MEASURED on /contests signed in with a $1504 balance, title right edge against
# its own column's right edge: +60.0px at 320, +36.0 at 344, +20.0 at 360, +1.6
# at 412. documentElement reported an untroubled 320/320, 344/344, 360/360 and
# 412/412 for every one of those — the page did not scroll sideways at any
# width, so no document-level check of this header could see it. A box that
# overflows its SIBLING's territory never reaches documentElement.
#
# WHY THIS APP NEEDED ITS OWN FIX. studio-engine shipped the same repair in
# 0.77.1, and turf-monster gets none of it: it renders its own fork of
# layouts/_navbar and declares its own `.user-nav-col` steps in
# app/assets/tailwind/application.css. The shapes differ too — this column
# carries a seeds bar with a hard `min-w-[8rem]`, which gives it a content floor
# the engine's column does not have — so the cap is this app's own arithmetic,
# not a copy of the engine's share.
#
# WHAT THIS TIER CAN AND CANNOT PROVE. It cannot prove containment; that needs a
# layout engine, and e2e/header_phone_width.spec.js measures it in pixels at six
# widths. What it CAN prove is that every part of the mechanism is still present
# and still agrees with itself — the chain, the caps, the floor, the preview
# that reviewers judge this header by, and the paragraph in docs/UI_PATTERNS.md
# that states the numbers. Each of those is a separate way for the fix to be
# half-undone without any pixel moving in a test.
class NavbarPhoneWidthTest < ActiveSupport::TestCase
  NAVBAR  = Rails.root.join("app/views/layouts/_navbar.html.erb")
  CSS     = Rails.root.join("app/assets/tailwind/application.css")
  PREVIEW = Rails.root.join("app/views/admin/navbar.html.erb")
  DOC     = Rails.root.join("docs/UI_PATTERNS.md")
  USER_NAV = Rails.root.join("app/views/components/_user_nav.html.erb")

  # STRIP COMMENTS BEFORE PARSING, and it is not tidiness. A naive CSS splitter
  # treats "everything since the last }" as a selector, so a `/* … */` block
  # immediately before a rule makes the next selector parse as `/*…*/.foo` and
  # match nothing — every declaration in that rule becomes invisible and the
  # sweep passes having read NOTHING. This file's rules all carry long comment
  # blocks directly above them, which is exactly that shape. The `refute_empty`
  # floors below exist for the same reason.
  def self.strip_css_comments(text) = text.gsub(%r{/\*.*?\*/}m, " ")

  def css = @css ||= self.class.strip_css_comments(CSS.read)

  # Every `.user-nav-col { … }` declaration block in source order — which is
  # band order, because the base rule precedes its media queries.
  def user_nav_col_blocks
    blocks = css.scan(/\.user-nav-col\s*\{([^}]*)\}/m).flatten
    refute_empty blocks, "no .user-nav-col rule parsed out of #{CSS.basename} — " \
                         "this guard reads those rules and can conclude nothing without them"
    blocks
  end

  def width_declarations
    widths = user_nav_col_blocks.filter_map { |b| b[/^\s*width:\s*([^;]+);/, 1]&.strip }
    assert_equal 3, widths.length,
                 "expected a width for each of the three bands, got #{widths.inspect}"
    widths
  end

  # ── A. the min-w-0 chain ────────────────────────────────────────────────

  test "every flex item between the row and the wordmark can shrink" do
    src = NAVBAR.read

    # The row's left item. `flex-1` alone is `flex: 1 1 0%` WITH `min-width:
    # auto`, which floors it at its own min-content — the 0% basis is irrelevant.
    assert_includes src, %(class="flex-1 min-w-0 px-4"),
                    "the row's left column must be allowed below its min-content"
    assert_includes src, %(class="flex items-center gap-6 min-w-0"),
                    "the inner flex that holds the logo link is a flex item too"
    # Written as a `class:` option on link_to, not a literal attribute.
    assert_match(/class: "nav-logo-link inline-flex items-center gap-3 group min-w-0"/, src,
                 "the logo link is a flex item too and belongs in the chain")

    # THE ONE THAT ACTUALLY BINDS. Removed one at a time and measured at all six
    # widths, only this one changes a pixel: without it both words return to
    # 88px at 320px and paint to x=156, 26px past a column ending at 130. The
    # other three measured identical with and without, so this file does not
    # claim they are load-bearing — it claims the chain is complete.
    assert_match(/<h1 class="nav-title[^"]*\bmin-w-0\b/, src,
                 "the wordmark's own box has to be allowed below its text — this is the " \
                 "link in the chain whose removal is measurable")
  end

  # ── B. the spans truncate, not the h1 ───────────────────────────────────

  test "both wordmark spans truncate individually" do
    src = NAVBAR.read

    # .nav-title is itself display:flex — a column below 768px, a baseline row
    # above — so the boxes that need clipping are the SPANS. `truncate` on the
    # h1 clips the flex CONTAINER and leaves its items drawing outside it, which
    # is the bug rather than the fix.
    assert_match(/<h1 class="nav-title[^"]*"><span class="dm-salmon truncate">Turf<\/span>/, src,
                 "the wordmark's first word must clip itself")
    assert_match(/<span class="dm-yellow tm-wordmark truncate">Monster<\/span>/, src,
                 "the wordmark's second word must clip itself")
    refute_match(/<h1 class="nav-title[^"]*\btruncate\b/, src,
                 "truncate belongs on the spans; on the flex container it clips the wrong box")
  end

  # THE OTHER HALF OF TRUNCATION, and the half that actually bit. Below 768px
  # .nav-title becomes a COLUMN, which puts its cross axis horizontal — so
  # align-items is what decides each word's WIDTH there. The base rule says
  # `baseline`, which in a column container falls back to flex-start and lets
  # each span size to its own max-content, leaving `truncate` nothing narrower
  # to clip against. Measured with everything else in place and this one
  # declaration missing: the h1 shrank to 46px at 320px and reported itself
  # contained while the "Monster" span stayed 88px and painted to x=156, 26px
  # past a left column ending at 130.
  test "the mobile stack gives each word a box it can be clipped to" do
    mobile = css[/@media\s*\(max-width:\s*767px\)\s*\{(.*?)\n  \}\n/m, 1]
    assert mobile, "the max-width: 767px band no longer parses out of #{CSS.basename}"

    title_rule = mobile[/\.nav-title\s*\{([^}]*)\}/m, 1]
    assert title_rule, "the mobile band must still restyle .nav-title"

    assert_match(/flex-direction:\s*column/, title_rule,
                 "this test's premise is that the mobile wordmark is a column")
    assert_match(/align-items:\s*stretch/, title_rule,
                 "a column container aligns on the HORIZONTAL axis, so the inherited " \
                 "`baseline` sizes every span to its own text and truncate clips nothing")
  end

  # ── C. the caps: a floor, a need, and three bands ───────────────────────

  test "the phone bands cap the column by what the left column needs" do
    base, small, = width_declarations

    # Not a constant and not a share: `100vw` minus what has to be LEFT. A
    # percentage answers "how much may this column take"; the question being
    # asked is "what must the column beside it keep".
    assert_equal "clamp(var(--user-nav-floor), calc(100vw - var(--nav-left-need)), 14rem)", base,
                 "the base band must cap the column, floored at its own contents"
    assert_equal "clamp(var(--user-nav-floor), calc(100vw - var(--nav-left-need)), 15rem)", small,
                 "the 400px band must cap the same way, or a 412px Pixel shows LESS of " \
                 "the wordmark than a 390px iPhone — measured 1.6px of spill against a " \
                 "contained 88px"
  end

  test "the desktop band keeps its bare clamp" do
    _, _, desktop = width_declarations

    assert_equal "clamp(16rem, 24vw, 20rem)", desktop,
                 "768px and up already measures the viewport through its own 24vw and has " \
                 "448px of slack at its breakpoint; the phone floor is a phone number"
    refute_includes desktop, "--nav-left-need",
                    "the desktop band must not be tied to the phone bands' arithmetic"
  end

  # THE FLOOR IS THIS COLUMN'S OWN CONTENT MINIMUM, and it is the number that
  # makes this app's cap different from the engine's. `width: min-content` on
  # the column measures exactly 190px = 11.875rem: the seeds bar's 8rem less the
  # row's -6px pull, plus the gap, the avatar's ml-3 inset, the 32px avatar and
  # the column's pr-4. Below it the seeds bar slides UNDER the avatar — and the
  # column's own scrollWidth keeps reporting a contented fit all the way down to
  # 122px, so that measurement cannot find it either.
  #
  # Derived from the seeds bar's declared minimum rather than restated, because
  # the floor is a CONSEQUENCE of that utility: change the bar and this number
  # is wrong, silently, in the direction that puts the overlap back.
  test "the column's floor is what its own contents need" do
    floor = user_nav_col_blocks.first[/--user-nav-floor:\s*([^;]+);/, 1]
    assert floor, "the base .user-nav-col rule must declare the floor"
    assert_equal "11.875rem", floor.strip

    bar_min = USER_NAV.read[/min-w-\[(\d+(?:\.\d+)?)rem\]/, 1]
    assert bar_min, "the seeds bar wrapper no longer declares a min-width in " \
                    "#{USER_NAV.basename}; this floor was derived from it"

    # 8rem bar - 6px pull + 0.5rem gap + 0.75rem avatar inset + 2rem avatar + 1rem padding
    derived = (bar_min.to_f * 16) - 6 + 8 + 12 + 32 + 16
    assert_equal derived / 16, floor.to_f,
                 "the floor (#{floor}) no longer equals what the column's contents need " \
                 "(#{derived}px derived from a #{bar_min}rem seeds bar). Retune both or " \
                 "the seeds bar goes back under the avatar."
  end

  # ── D. the caps are ordered ─────────────────────────────────────────────

  test "a wider band never caps the column narrower than a smaller one" do
    ceilings = width_declarations.map { |w| w[/,\s*(\d+(?:\.\d+)?)rem\)\s*\z/, 1] || w[/,\s*(\d+(?:\.\d+)?)rem\)/, 1] }
    assert_equal 3, ceilings.compact.length, "every band must end in a rem ceiling: #{ceilings.inspect}"

    values = ceilings.map(&:to_f)
    assert_equal values.sort, values,
                 "the rem ceilings must not decrease as the viewport grows (#{values.inspect}) — " \
                 "a wider phone showing LESS of the wordmark is the regression this ordering stops"
  end

  # ── E. the dead class is gone, everywhere ───────────────────────────────

  # `.username-cap` never existed as an element in this app: the name is capped
  # by Tailwind utilities on the button (`max-w-[4.5rem] min-[400px]:max-w-[6rem]
  # md:max-w-[7rem]`) and faded by navUsernameFade's mask. Three rules under that
  # name sat in the navbar-review page claiming a 5/6/7rem cap that was never in
  # force, and they disagreed with the live 4.5rem at the narrow band.
  #
  # Swept over SHIPPING SOURCE with comments stripped, so the note recording the
  # removal is not mistaken for the thing it removed, and so a rule re-added
  # under a comment block cannot hide from the parse.
  DEAD_CLASS_SURFACES = %w[
    app/views/**/*.erb
    app/assets/tailwind/**/*.css
    app/javascript/**/*.js
  ].freeze

  def strip_comments(rel, text)
    text = text.gsub(/<%#.*?%>/m, " ") if rel.end_with?(".erb")
    self.class.strip_css_comments(text).gsub(%r{^\s*//.*$}, " ")
  end

  test "no shipping surface still styles a class nothing carries" do
    files = DEAD_CLASS_SURFACES.flat_map { |g| Dir[Rails.root.join(g)] }
    assert_operator files.size, :>=, 50,
                    "the sweep reached #{files.size} files; it cannot conclude anything " \
                    "about a repo it did not read"

    offenders = files.map { |f| Pathname(f).relative_path_from(Rails.root).to_s }
                     .select { |rel| strip_comments(rel, Rails.root.join(rel).read).include?("username-cap") }

    assert_empty offenders,
                 "these still style .username-cap, which no element carries: #{offenders.join(', ')}"
  end

  test "the username is capped where it actually is capped" do
    src = USER_NAV.read
    button = src[/<button[^>]*data-username-display[^>]*>/m] || src[/<button[^>]*nav-username[^>]*>/m]
    assert button, "the username button no longer parses out of #{USER_NAV.basename}"

    # The premise of deleting .username-cap: the real cap is here. If these move,
    # the doc paragraph that now names them is wrong too.
    %w[max-w-[4.5rem] min-[400px]:max-w-[6rem] md:max-w-[7rem] overflow-hidden].each do |utility|
      assert_includes button, utility,
                      "the live username cap must stay on the button itself: #{button}"
    end
  end

  # ── F. the reviewer's instrument tells the truth ────────────────────────

  # /admin/navbar is where this header is judged, and it re-keys the shipped
  # media queries onto a wrapper because a media query cannot fire for a
  # CONTAINER at a fixed viewport width. A preview that restates the numbers
  # instead of reading them drifts — and it had: its desktop step read a flat
  # 20rem against a shipped clamp(16rem, 24vw, 20rem), so the 1032px Tablet
  # preview drew a 320px column where production draws 256px.
  test "the navbar preview re-keys the shipped caps rather than restating them" do
    preview = self.class.strip_css_comments(PREVIEW.read.gsub(/<%#.*?%>/m, " "))

    tiny = preview[/\.navbar-preview\.bp-tiny \.user-nav-col \{([^}]*)\}/, 1]
    small = preview[/\.navbar-preview\.bp-small \.user-nav-col \{([^}]*)\}/, 1]
    desktop = preview[/\.navbar-preview\.is-desktop \.user-nav-col \{([^}]*)\}/, 1]
    [tiny, small, desktop].each_with_index do |rule, i|
      assert rule, "preview band #{i} no longer parses out of #{PREVIEW.basename}"
    end

    # Percent there, vw here, and they are the same number: a literal 100vw
    # inside a 390px preview box on a 1400px monitor resolves to 1400px. The
    # frame term adds the preview's own border back, because the slider and the
    # label count the border box while a percentage resolves against the content
    # box.
    assert_includes tiny,
                    "clamp(var(--user-nav-floor), calc(100% + 2 * var(--preview-frame) - var(--nav-left-need)), 14rem)"
    assert_includes small,
                    "clamp(var(--user-nav-floor), calc(100% + 2 * var(--preview-frame) - var(--nav-left-need)), 15rem)"
    assert_includes desktop, "clamp(16rem, calc(24% + 0.48 * var(--preview-frame)), 20rem)"

    # THE BAND-SPECIFIC NUMBER EACH PREVIEW HAS TO RESTATE, derived rather than
    # asserted as a literal — and the reason both are checked is that reading
    # the clamp expression alone is not enough. Two separate versions of this
    # block were green on every assertion above while drawing a column
    # production does not: one carried the previous band's 11.875rem after the
    # shipped value moved to 12.25rem, and one left the TINY band to inherit
    # --nav-left-need, which on a reviewer's desktop is set by the shipped
    # `@media (min-width: 400px)` query firing for real — measured 190px against
    # the 212px a 390px phone actually gets.
    [[tiny, 0, "tiny"], [small, 1, "small"]].each do |rule, band, name|
      shipped = user_nav_col_blocks[band][/--nav-left-need:\s*([^;]+);/, 1]&.strip
      assert shipped, "the shipped #{name} band no longer declares --nav-left-need"
      preview_need = rule[/--nav-left-need:\s*([^;]+);/, 1]&.strip
      assert_equal shipped, preview_need,
                   "the #{name} preview's --nav-left-need (#{preview_need.inspect}) has drifted " \
                   "from the shipped band (#{shipped.inspect}). Inheriting it is not an option: " \
                   "this page is opened on a desktop, where the 400px media query fires for real " \
                   "and sets the property on every preview on the page."
    end

    [tiny, small, desktop].each do |rule|
      refute_match(/\bvw\b/, rule,
                   "a viewport unit inside a fixed-width preview container measures the " \
                   "MONITOR, not the simulated device: #{rule}")
    end

    # The mobile preview turns the wordmark into a column, so it owes the same
    # align-items reset the shipped band carries — without it the preview draws
    # the spill this task removed.
    mobile_title = preview[/\.navbar-preview\.is-mobile \.nav-title \{([^}]*)\}/, 1]
    assert mobile_title, "the preview's mobile .nav-title rule no longer parses"
    assert_match(/flex-direction:\s*column/, mobile_title)
    assert_match(/align-items:\s*stretch/, mobile_title,
                 "align-items rides along with flex-direction; leaving it out makes the " \
                 "preview show a header no phone draws")
  end

  # ── G. the document states numbers it does not own ──────────────────────

  # docs/UI_PATTERNS.md carries a band table with the `.user-nav-col` value for
  # each of the three bands. A value written by hand rots the moment the rule
  # moves, and a stale number does not read as stale — it reads as freshly
  # verified. So derive both sides and assert they agree.
  test "the responsive band table quotes the shipped widths" do
    rows = DOC.read.scan(/^\|\s*\*\*[^|]*\*\*\s*\|\s*\d+px\s*\|\s*([^|]+?)\s*\|/)
    assert_equal 3, rows.length,
                 "the band table no longer parses out of #{DOC.basename} (found #{rows.length} rows)"

    documented = rows.flatten.map { |v| v.gsub(/\s+/, " ").strip }
    shipped = width_declarations.map { |w| w.gsub("var(--user-nav-floor)", "11.875rem")
                                            .gsub("var(--nav-left-need)", nil.to_s) }

    # The doc spells the vars out, because a reader of prose cannot resolve them.
    expected = [
      "clamp(11.875rem, 100vw - 11.125rem, 14rem)",
      "clamp(11.875rem, 100vw - 12.25rem, 15rem)",
      "clamp(16rem, 24vw, 20rem)"
    ]
    assert_equal expected, documented,
                 "the band table's .user-nav-col column disagrees with the shipped rules"

    # And the substitutions it spells out are the ones actually declared, so the
    # expectation above cannot quietly drift away from the stylesheet.
    needs = user_nav_col_blocks.filter_map { |b| b[/--nav-left-need:\s*([^;]+);/, 1]&.strip }
    assert_equal %w[11.125rem 12.25rem], needs,
                 "the two phone bands' --nav-left-need values moved; the doc table's " \
                 "spelled-out numbers (#{expected.first}, #{expected[1]}) are now wrong"
    refute_empty shipped
  end
end
