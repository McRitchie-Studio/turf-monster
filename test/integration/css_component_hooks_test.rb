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

  # The hold-to-confirm button and its fizz used to be pinned here. Both halves
  # moved to studio-engine 0.56 (studio/_hold_button + the ACTION family in
  # engine-motion.css), so the markup<->stylesheet contract is asserted there —
  # test/views/hold_button_test.rb, test/views/engine_motion_css_test.rb and the
  # five mutation-verified specs in its browser lane. What stayed this app's own
  # is the PALETTE it feeds in: test/integration/hold_button_fizz_palette_test.rb.

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
