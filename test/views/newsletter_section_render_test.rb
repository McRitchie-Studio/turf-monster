require "test_helper"

# [component] The extracted newsletter card, rendered in both of its states.
#
# It is ONE partial with TWO call sites now — /account wraps it in its own card,
# the /profile row gets its chrome from the engine's section wrapper — so the
# thing worth pinning is that the partial itself carries NEITHER, and that each
# state offers the right control.
class NewsletterSectionRenderTest < ActionView::TestCase
  # Returns THIS render's markup. ActionView::TestCase#rendered ACCUMULATES across
  # calls, so a test that renders both states would see the union and every
  # refute_includes below would pass vacuously — the same trap
  # test/views/tokens_pack_button_test.rb documents. Use the return value.
  def render_card(subscribed:)
    @current_user = users(:alex)
    @current_user.update!(
      joined_email_list_at: subscribed ? 1.day.ago : nil,
      left_email_list_at: subscribed ? nil : 1.day.ago
    )
    render partial: "accounts/newsletter_section", locals: { user: @current_user }
  end

  # NO CARD, NO HEADING. Carrying either would nest a card inside the engine's
  # section wrapper on /profile — two borders, doubled padding, two headings.
  test "the partial carries no chrome of its own" do
    html = render_card(subscribed: false)

    refute_match(/class="[^"]*\bcard\b/, html, "the call site owns the card, not the partial")
    refute_match(/<h2/, html, "the call site owns the heading — /profile gets it from the row's title:")
  end

  test "an unsubscribed account is offered this app's subscribe modal" do
    html = render_card(subscribed: false)

    assert_includes html, "$store.modals.open('newsletter-subscribe')"
    assert_includes html, "25 seeds", "the reward is the reason this app replaced the engine's row"
  end

  test "a subscribed account is offered the confirm-before-leaving modal" do
    html = render_card(subscribed: true)

    assert_includes html, "$store.modals.open('unsubscribe-confirm')",
      "leaving costs seeds-earning standing — it must ask, not just submit"
    assert_includes html, "Subscribed"
  end

  # Both states ship in the markup and are toggled by x-show, so the card can
  # respond to the newsletter-state-changed event without a round trip. That is
  # also why both assertions above can pass on one render.
  test "both states are present and driven by the shared event" do
    html = render_card(subscribed: false)

    assert_includes html, "newsletter-state-changed"
    assert_includes html, 'x-show="subscribed"'
    assert_includes html, 'x-show="!subscribed"'
  end
end
