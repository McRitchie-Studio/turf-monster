require "test_helper"

# Component tier for the application.css dedupe (task
# dedupe-turf-application-css). The refactor deleted duplicate CSS
# definitions; the surviving copies style class hooks that live in rendered
# markup. These tests pin the markup <-> stylesheet contract from the
# component side: the partials still emit every hook class, and the
# stylesheet source still defines styling for each of them — so deleting
# either half (or deleting the wrong duplicate) goes red here, not in QA.
class CssComponentHooksTest < ActionDispatch::IntegrationTest
  CSS = File.read(Rails.root.join("app/assets/tailwind/application.css"))

  test "hold button partial renders every hook the hold-btn utility styles" do
    html = ApplicationController.render(partial: "shared/hold_button")
    doc = Nokogiri::HTML::DocumentFragment.parse(html)

    button = doc.at_css("button.hold-btn")
    assert button, "hold button must render with the .hold-btn class"

    assert doc.at_css(".hold-btn > .hold-icon > svg.progress circle"), "progress ring markup"
    assert doc.at_css(".hold-btn > .hold-icon > svg.tick polyline"), "tick markup"
    assert_equal 4, doc.css(".hold-btn ul.hold-text > li").size,
      "sliding text needs 4 slots (default/hold/success/error)"
    assert doc.at_css(".hold-btn .nudge-debug .countdown-num"), "debug countdown markup"

    # The styling for all of the above lives INSIDE @utility hold-btn (the
    # dedupe deleted the bare hold-icon/hold-text/state utilities).
    assert_includes CSS, "@utility hold-btn", "@utility hold-btn must define the component"
    %w[.hold-icon .hold-text .nudge-debug].each do |hook|
      assert_match(/@utility hold-btn \{.*#{Regexp.escape(hook)}/m, CSS,
        "#{hook} must be styled within @utility hold-btn")
    end
  end

  test "hold button renders a fizz layer the hold-stack utility animates behind it" do
    html = ApplicationController.render(partial: "shared/hold_button", locals: { hold_id: "desktop" })
    doc = Nokogiri::HTML::DocumentFragment.parse(html)

    # The bubbles must be a SIBLING the button paints over, never a child: a
    # child cannot get behind the button's own background, because the button's
    # transform makes it a stacking context.
    layer = doc.at_css(".hold-stack > .hold-fizz")
    assert layer, "fizz layer must render inside the stack, outside the button"
    assert doc.at_css(".hold-stack > button.hold-btn"), "the button is the fizz layer's sibling"
    assert_nil doc.at_css(".hold-btn .fizz-bit"), "no bubble may live inside the button"
    assert_equal "true", layer["aria-hidden"], "decoration must be hidden from assistive tech"

    bits = doc.css(".hold-stack > .hold-fizz:not(.hold-fizz-extra) > .fizz-bit")
    assert_equal 30, bits.size, "the resting layer needs its full bubble table (5 per zone)"

    # Each bubble carries its own placement + animation table inline; the
    # keyframes read them back as vars, so a dropped property = a dead bubble.
    bits.each do |bit|
      style = bit["style"].to_s
      %w[left: top: --fs: --fx: --fy: --fd: --ft: --fc:].each do |prop|
        assert_includes style, prop, "every bubble needs #{prop}"
      end
      assert_match(/--fc:var\(--fizz-c-\d+, hsl\(/, style,
        "a bubble reads its color slot and falls back to its candy hue")
    end

    # A static palette paints the slots; the board binds the same slots live.
    dressed = Nokogiri::HTML::DocumentFragment.parse(
      ApplicationController.render(partial: "shared/hold_button",
                                   locals: { hold_id: "teams", fizz_colors: %w[#ff0000 #00ff00] })
    )
    assert_includes dressed.at_css(".hold-stack")["style"], "--fizz-c-1:#ff0000"
    assert_includes dressed.at_css(".hold-stack")["style"], "--fizz-c-2:#00ff00"

    bound = Nokogiri::HTML::DocumentFragment.parse(
      ApplicationController.render(partial: "shared/hold_button",
                                   locals: { hold_id: "bound", fizz_bind: "fizzPalette" })
    )
    assert_equal "fizzPalette", bound.at_css(".hold-stack")[":style"]

    # Opt-out for any call site that wants the flat button back.
    flat = Nokogiri::HTML::DocumentFragment.parse(
      ApplicationController.render(partial: "shared/hold_button", locals: { fizz: false })
    )
    assert_nil flat.at_css(".hold-fizz"), "fizz: false must render no particle layer"

    # Styling lives INSIDE @utility hold-stack (the dedupe rule), the keyframes
    # at file level, and reduced motion switches the whole thing off.
    %w[.fizz-bit .hold-fizz].each do |hook|
      assert_match(/@utility hold-stack \{.*#{Regexp.escape(hook)}/m, CSS,
        "#{hook} must be styled within @utility hold-stack")
    end
    assert_match(/@utility hold-stack \{.*isolation: isolate/m, CSS,
      "the stack must isolate its z-order from the page")
    assert_match(/@utility hold-stack \{.*:has\(> \.hold-btn\.process\)/m, CSS,
      "hold state lives on the button, so the stack reads it with :has()")

    # Lively is the DEFAULT: rest at a full boil, and hover doubles the COUNT —
    # a second scatter, seeded apart so it lands in the first one's gaps, fading
    # in over it. Speed must NOT change.
    assert doc.at_css(".hold-stack.fizz-lively"), "lively is the default level"
    assert_equal 2, doc.css(".hold-stack > .hold-fizz").size, "lively renders both layers"
    assert doc.at_css(".hold-stack > .hold-fizz-extra"), "the hover layer must be marked"
    assert_equal 60, doc.css(".fizz-bit").size, "hover doubles 30 bubbles to 60"
    # Seeded apart, or the second layer would sit exactly on top of the first.
    assert_not_equal doc.css(".hold-fizz:not(.hold-fizz-extra) > .fizz-bit").map { |b| b["style"] },
                     doc.css(".hold-fizz-extra > .fizz-bit").map { |b| b["style"] },
                     "the extra scatter must fill gaps, not shadow the base one"
    # The layers split each zone's three colors: light rests, dark and alt arrive
    # on hover (slots run light, dark, alt per team, six teams = eighteen).
    slot_of = ->(bit) { bit["style"][/--fizz-c-(\d+)/, 1].to_i }
    assert_equal [ 1, 4, 7, 10, 13, 16 ],
                 doc.css(".hold-fizz:not(.hold-fizz-extra) > .fizz-bit").map(&slot_of).uniq.sort,
                 "the resting layer wears each team's light color"
    assert_equal [ 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18 ],
                 doc.css(".hold-fizz-extra > .fizz-bit").map(&slot_of).uniq.sort,
                 "the hover layer alternates each team's dark and its alt"

    # Calm is the quiet alternative — one layer, and it must be asked for.
    calm = Nokogiri::HTML::DocumentFragment.parse(
      ApplicationController.render(partial: "shared/hold_button",
                                   locals: { hold_id: "calm", fizz_level: :calm })
    )
    assert_nil calm.at_css(".fizz-lively"), "fizz_level: :calm drops the modifier"
    assert_nil calm.at_css(".hold-fizz-extra"), "calm pays for no second layer"
    assert_equal 30, calm.css(".fizz-bit").size

    assert_match(/@utility hold-stack \{.*&\.fizz-lively \.fizz-bit/m, CSS,
      "the lively rest rule must exist")
    assert_match(/@utility hold-stack \{.*&:not\(\.fizz-lively\):has\(> \.hold-btn:hover/m, CSS,
      "calm's speed-up hover must not reach a lively button")
    assert_match(/&\.fizz-lively:has\(> \.hold-btn:hover[^)]*\)[^{]*> \.hold-fizz-extra \{\s*opacity: 1/m, CSS,
      "lively's hover reveals the extra layer")
    assert_match(/& > \.hold-fizz-extra \{\s*opacity: 0;\s*transition: opacity/m, CSS,
      "and it fades, rather than snapping, on the way in and out")
    %w[fizz-simmer fizz-boil fizz-burst].each do |frames|
      assert_match(/@keyframes #{frames}\s*\{/, CSS, "@keyframes #{frames} must exist")
    end
    assert_match(/@media \(prefers-reduced-motion: reduce\) \{\s*\.hold-stack \.fizz-bit \{\s*animation: none/m, CSS,
      "reduced motion must stop the bubbles")
  end

  test "hold button face wears the brand green — resting gradient, confirmed in the same family" do
    # The resting face is a gradient (flat read as a paint chip), and the
    # confirmed face stays in the brand green rather than jumping to the mint
    # it used to use — with a WHITE check, because mint-on-mint was invisible.
    face = CSS[/@utility hold-btn \{.*?\n\}/m]
    assert face, "@utility hold-btn must define the face"

    assert_match(/--bg-image: linear-gradient\(/, face, "the resting face is a gradient")
    assert_match(/--progress-success: #f6f8ff/, face, "the check is white on the green face")
    assert_match(/--success-from: var\(--hold-success-from, rgb\(var\(--color-primary-rgb\)\)\)/, face,
      "confirmed starts at the brand green (Deep forest)")
    assert_match(/--success-to: var\(--hold-success-to, rgb\(var\(--color-primary-900-rgb\)\)\)/, face,
      "and drops into the near-black green")
    assert_match(/&\.process \{[^}]*--bg-image: none/m, face, "the hold face stays flat")
    assert_match(/&\.error \{[^}]*--bg-image: none/m, face, "the blocked face stays flat")
    refute_match(/#06d6a0/, face, "the confirmed face must not go back to mint")
    refute_match(/rgba\(6, 214, 160/, face, "nor its mint glow")
  end

  test "gear sidebar renders the nav emoji swap hooks the stylesheet styles" do
    log_in_as(users(:alex))
    get account_path
    assert_response :success

    doc = Nokogiri::HTML5.parse(response.body)
    swap = doc.at_css(".group .nav-emoji-swap")
    assert swap, "gear sidebar rows must render .nav-emoji-swap inside a .group row"
    assert swap.at_css(".nav-emoji-base"), "base emoji span"
    assert swap.at_css(".nav-emoji-hover"), "hover emoji span"

    # One surviving definition block styles the swap (hover slide keyed on .group).
    assert_includes CSS, ".nav-emoji-swap {", "stylesheet must define .nav-emoji-swap"
    assert_includes CSS, ".group:hover .nav-emoji-hover", "hover reveal rule must survive"
  end

  test "dev-mode debug paint stays scoped and its markup hooks stay styled" do
    log_in_as(users(:alex))
    get account_path
    assert_response :success

    # The layout binds .dev-mode via Alpine on <body>; the dm-* hooks in the
    # navbar markup must keep a scoped definition (never bare/unscoped).
    assert_includes response.body, "'dev-mode': $store.devMode"
    doc = Nokogiri::HTML5.parse(response.body)
    dm_classes = doc.css("[class*='dm-']").flat_map { |el| el["class"].split }
                    .grep(/\Adm-[a-z]+\z/).uniq
    assert_not_empty dm_classes, "expected dm-* diagnostic hooks in the chrome markup"
    dm_classes.each do |cls|
      assert_match(/@utility #{Regexp.escape(cls)} \{(?:\s*\/\*.*?\*\/)*\s*\.dev-mode &/m, CSS,
        "#{cls} must be defined scoped under .dev-mode")
    end
  end
end
