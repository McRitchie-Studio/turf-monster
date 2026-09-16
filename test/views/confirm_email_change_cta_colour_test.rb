require "test_helper"

# [component] THE CONFIRM-EMAIL-CHANGE CTA'S LABEL COLOUR IS SET BY A CLASS
# THAT EXISTS.
#
# ── WHY THIS TEST EXISTS SEPARATELY FROM THE CLASS GUARD ─────────────────────
#
# The shared CssClassGuard finds phantom classes by reading HTML `class="…"`
# ATTRIBUTES out of an ERB template. This CTA is a `button_to` whose classes
# arrive as a Ruby OPTION (`class: "…"`), which that reader cannot match and
# never could. So the guard was GREEN across the entire life of the defect:
#
#     class: "... bg-primary text-on-primary ..."
#
# `bg-primary` resolved — the button filled green. `text-on-primary` is defined
# by no stylesheet in this app, so the LABEL COLOUR was simply never set and
# the label rendered in whatever ink it inherited from the page. On a page
# users reach by clicking a link in an email, confirming an account email
# change.
#
# A test that asserted "the guard is green" would therefore have proved
# NOTHING here. This one asks a question the source reader cannot ask: render
# the page, take the button's ACTUAL class list, and require that (a) every
# name in it resolves, and (b) at least one of them declares a `color`. (b) is
# the half that bites — a phantom label colour leaves the list carrying a fill
# and no ink.
#
# CONTROL: reverting the view to `bg-primary text-on-primary` must fail this
# test. Recorded on the task; re-run it before trusting any edit here.
class ConfirmEmailChangeCtaColourTest < ActionDispatch::IntegrationTest
  setup do
    @alex = users(:alex)
    @alex.update!(email_verified_at: Time.current)
  end

  test "the CTA's classes all resolve and at least one of them sets a colour" do
    classes = rendered_cta_classes

    phantoms = classes.reject { |name| CssClassGuard.defined_in_css?(name) }
    assert_empty phantoms,
                 "the confirm CTA names #{phantoms.join(', ')}, which no stylesheet defines — " \
                 "each one paints nothing. Full list: #{classes.join(' ')}"

    colouring = classes.select { |name| declares_colour?(name) }
    assert colouring.any?,
           "none of the confirm CTA's classes (#{classes.join(' ')}) declares a `color`, so the " \
           "label takes whatever ink it inherits — on a filled button that is how a label goes " \
           "unreadable. This is the exact defect `text-on-primary` shipped, and the class guard " \
           "cannot see it because these classes are a Ruby `class:` option, not a class= attribute."
  end

  # THE CONTROL FOR THE `declares_colour?` PREDICATE ITSELF. Without it the
  # assertion above could pass on a predicate that answers "yes" to everything,
  # or fail closed on one that answers "no" to everything.
  test "the colour predicate separates a fill from an ink" do
    assert declares_colour?("btn-primary"),
           "btn-primary sets `color: var(--btn-primary-fg, #fff)` — the predicate must see it"
    assert_not declares_colour?("bg-primary"),
           "bg-primary sets `background-color` only. If the predicate counts that as a colour " \
           "it would have passed the original defect, which is the whole point of this file."
    assert_not declares_colour?("text-on-primary"),
           "the retired phantom defines no rule at all, so it can declare nothing"
    assert_not declares_colour?("w-full"),
           "a width utility declares no colour"
  end

  private

  # The class list the BROWSER would see, taken from a real render rather than
  # from the template — this is the only way to observe a `class:` option.
  def rendered_cta_classes
    token = Rails.application.message_verifier(AccountsController::EMAIL_CHANGE_TOKEN_KEY).generate(
      { user_id: @alex.id, new_email: "colour-check@example.com",
        current_email: @alex.email, requested_at: Time.current.to_i },
      expires_in: 30.minutes
    )

    get confirm_email_change_path(token: token)
    assert_response :success

    button = css_select("form[action='#{apply_email_change_path}'] button[type=submit], " \
                        "form[action='#{apply_email_change_path}'] input[type=submit]").first
    assert button, "the confirm CTA did not render — this test would pass vacuously without it"

    names = button["class"].to_s.split
    assert names.any?, "the confirm CTA rendered with NO classes at all; nothing below proves anything"
    names
  end

  # Does this class name's compiled rule declare the `color` PROPERTY?
  #
  # Deliberately NOT a substring search for "color:" — `background-color:` and
  # `border-color:` both contain it, and counting either would let a button
  # with a fill and no ink pass. The property has to start a declaration.
  def declares_colour?(name)
    escaped = Regexp.escape(CssClassGuard.css_escape(name))
    # The base rule: this class alone as the whole selector, no pseudo, no
    # descendant — the rule that applies to the element at rest.
    CssClassGuard.stylesheet
                 .scan(/(?<![\\\w.#-])\.#{escaped}\s*\{([^{}]*)\}/)
                 .any? { |(body)| body.match?(/(?:\A|[;{])\s*color\s*:/) }
  end
end
