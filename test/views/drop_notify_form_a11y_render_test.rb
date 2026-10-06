require "test_helper"

# [component] The notify-me form's focus and error wiring, as markup. The
# runtime half (focus really moves, aria-invalid really flips) is
# e2e/notify_form_a11y.spec.js; this tier pins the shape both surfaces (the
# /turf-monster-v2 section and the drop-notify modal) get from the one partial,
# including the no-JS round trip, which has no Alpine to set anything.
# Return values, not #rendered (it accumulates across calls).
class DropNotifyFormA11yRenderTest < ActionView::TestCase
  def form_html(**locals)
    render(partial: "pages/drop_notify_form", locals: locals)
  end

  def form(**locals)
    Nokogiri::HTML.fragment(form_html(**locals))
  end

  test "the success message can take focus, and the form moves focus to it on success" do
    html = form_html(id_prefix: "drop_modal", test_id: "drop-modal", card: false)
    success = Nokogiri::HTML.fragment(html).at_css('[data-test="drop-modal-success"]')
    assert_equal "-1", success["tabindex"]
    assert_equal "success", success["x-ref"]
    assert_includes html, "$watch('state', function (value) { if (value === 'done') " \
                          "$nextTick(function () { setTimeout(function () { $refs.success.focus(); }); }); })"
  end

  test "the input names the error line and goes invalid only in the error state" do
    html = form_html(id_prefix: "drop_signup")
    input = Nokogiri::HTML.fragment(html).at_css("#drop_signup_email")
    assert_nil input["aria-invalid"], "an untouched field is not invalid"
    assert_equal "drop_signup_help", input["aria-describedby"]
    # Alpine's bindings, read from the raw markup: Nokogiri's HTML4 parser is
    # not reliable on ":"- and "@"-prefixed attribute names.
    assert_includes html, %(:aria-invalid="state === 'error' ? 'true' : null")
    assert_includes html, %(:aria-describedby="state === 'error' ? 'drop_signup_error drop_signup_help' : 'drop_signup_help'")

    region = Nokogiri::HTML.fragment(html).at_css("#drop_signup_error")
    assert region, "the id the input names exists"
    alert = region.at_css('p[role="alert"]')
    assert alert, "and it holds the mounted live region"
    assert_equal "", alert.text, "empty until Alpine writes the failure"
  end

  test "the no-JS error round trip is invalid and described with no Alpine" do
    doc = form(initial: "error", id_prefix: "drop_signup")
    input = doc.at_css("#drop_signup_email")
    assert_equal "true", input["aria-invalid"]
    assert_equal "drop_signup_error drop_signup_help", input["aria-describedby"]
    assert_includes doc.at_css("#drop_signup_error").inner_html, "Enter a valid email address."
  end

  test "the section and the modal get distinct ids, so both can sit in one page" do
    section = form(id_prefix: "drop_signup")
    modal = form(id_prefix: "drop_modal", test_id: "drop-modal", card: false)
    assert section.at_css("#drop_signup_error")
    assert modal.at_css("#drop_modal_error")
    assert_nil section.at_css("#drop_modal_error")
  end
end
