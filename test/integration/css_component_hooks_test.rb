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

    bits = doc.css(".hold-stack > .hold-fizz > .fizz-bit")
    assert_equal 26, bits.size, "the fizz layer needs its full bubble table"

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
    %w[fizz-simmer fizz-boil fizz-burst].each do |frames|
      assert_match(/@keyframes #{frames}\s*\{/, CSS, "@keyframes #{frames} must exist")
    end
    assert_match(/@media \(prefers-reduced-motion: reduce\) \{\s*\.hold-stack \.fizz-bit \{\s*animation: none/m, CSS,
      "reduced motion must stop the bubbles")
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
