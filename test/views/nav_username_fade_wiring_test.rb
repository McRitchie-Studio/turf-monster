require "test_helper"

# [component] The navbar username's overflow fade mask — IS IT WIRED.
#
# The bug this file exists for (task: fade-mask-follows-face-swap): the button
# is `overflow-hidden whitespace-nowrap`, and the mask that turns its hard cut
# into a taper was decided ONCE, in an inline Alpine `init()`. init() runs while
# the balance slot beside it is still on its cold-cache "loading" render, so the
# username has the whole column and fits. Everything that squeezes it afterwards
# — the balance hydrate, applyBalanceSlotRule() swapping the slot to its wider
# "Free Entry" face on a first mint, a resize across the 768-1279px squeeze band
# — arrived after the only measurement anyone took. MEASURED at six widths after
# a live face swap, the painted right edge was byte-identical to having no mask
# at all.
#
# WHAT THIS TIER CAN AND CANNOT PROVE. It cannot prove the mask PAINTS; that
# needs a layout engine and a compositor, and e2e/navbar_layout.spec.js asserts
# it in pixels ("a live balance-slot face swap re-fades the clipped username").
# What it CAN prove, and what no browser spec would report usefully, is that the
# component RESOLVES AT ALL — because the failure mode is silent. Alpine boots
# deferred and evaluates x-data BEFORE the importmap modules load (see the
# header of shared/_alpine_factories.html.erb), so a factory that lives only in
# app/javascript/*.js is `undefined` at that moment: Alpine logs to the console,
# the button renders perfectly, and the mask simply never appears again.
class NavUsernameFadeWiringTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:sam)
    log_in_as(@user)
    get contests_path
    assert_response :success
    @body = response.body
  end

  # The username button's tag, from `data-username-display` back to its `<`.
  def username_button_tag
    at = @body.index('data-username-display="true"')
    assert at, "the navbar must render the username button"
    open_at = @body.rindex("<button", at)
    close_at = @body.index(">", at)
    @body[open_at..close_at]
  end

  def username_x_data
    tag = username_button_tag
    m = tag.match(/x-data="([^"]*)"/)
    assert m, "the username button must carry an x-data component: #{tag}"
    m[1]
  end

  test "the mask is driven by a factory this same document defines" do
    expression = username_x_data
    factory = expression[/\A\s*([A-Za-z_$][\w$]*)\s*\(/, 1]

    assert factory,
           "the username's x-data must CALL a named factory (got #{expression.inspect}). " \
           "An inline object literal is the shape that shipped the bug: its init() " \
           "body is the only place a measurement can live, and it runs exactly once."

    definition_at = @body.index("window.#{factory} =")
    assert definition_at,
           "x-data names #{factory}(), but nothing in this document defines " \
           "window.#{factory}. Alpine evaluates x-data before the importmap " \
           "modules load, so a definition that lives only in app/javascript/ " \
           "resolves to undefined and the mask silently never applies. " \
           "Define it in shared/_alpine_factories.html.erb."

    assert definition_at < @body.index('data-username-display="true"'),
           "window.#{factory} must be defined BEFORE the button that uses it — " \
           "shared/alpine_factories renders early in <body> for exactly this reason."
  end

  test "the mask flag is reactive state, not a one-shot measurement" do
    tag = username_button_tag

    refute_includes username_x_data, "scrollWidth",
                    "measuring inside the x-data EXPRESSION is the bug: the " \
                    "expression is evaluated once, at init, before the balance " \
                    "hydrate has squeezed the button. The measurement belongs in " \
                    "a factory that can re-run it when the box changes."

    style = tag[/x-bind:style="([^"]*)"/, 1]
    assert style, "the mask has to be bound, not hard-coded: #{tag}"
    assert_includes style, "mask-image",
                     "the fade is a mask-image gradient"
    assert_match(/\Aoverflows\s*\?/, style,
                 "the mask must read the component's reactive flag, so a " \
                 "re-measurement repaints it: #{style.inspect}")
  end

  # The factory's contract, stated where a reader of the button will find it.
  # ResizeObserver is the mechanism BECAUSE it watches the effect (the box moved)
  # rather than any one cause: the balance hydrate calls applyBalanceSlotRule()
  # directly and dispatches no event, so an event subscription would have missed
  # the very path that first showed the bug.
  test "the factory re-measures on box changes and cleans up after itself" do
    factory_src = @body[/window\.navUsernameFade = function[\s\S]{0,1200}?\n  \};/]
    assert factory_src, "shared/_alpine_factories must define window.navUsernameFade"

    assert_includes factory_src, "ResizeObserver",
                    "the flag has to follow the BOX, not one of the causes that move it"
    assert_includes factory_src, "destroy()",
                    "the observer belongs to the component instance and must be " \
                    "disconnected with it, or a Turbo navigation leaves observers behind"
    assert_includes factory_src, "disconnect()",
                    "destroy() must actually release the observer"
  end
end
