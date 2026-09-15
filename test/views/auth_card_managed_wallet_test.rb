require "test_helper"

# [component] The unified sign-in card, with and without the gifted-newcomer
# nudge.
#
# WHAT THIS TIER ADDS over the integration test that renders the same card
# through a real request: the card in ISOLATION, so a failure names the partial
# rather than the eight before_actions and three redirects a /signin request
# walks through to reach it.
#
# IT ASSERTS THE CARD'S OWN WRAPPER, never the Solana mark. The layout's shared
# modal host renders the Connect Wallet picker — mark and all — on every page of
# the app, signed out or not, so a scan for the mark finds a hit whether this
# card drew a button or not. Measured in a real browser: suppressing the card's
# button takes the page's occurrences of solana-mark.svg from three to two, not
# to zero.
class AuthCardManagedWalletTest < ActionView::TestCase
  # The two helpers the card reads. Stubbed at the view rather than the
  # controller because this tier renders the partial, not the request.
  def render_card(nudged:, user: nil)
    view.define_singleton_method(:managed_wallet_onboarding?) { nudged }
    view.define_singleton_method(:current_user) { user }
    render partial: "shared/auth_card"
  end

  # ActionView::TestCase#rendered ACCUMULATES across calls in one test, so an
  # absence read off it would pass vacuously against the union of every render
  # in this file. Always assert on the return value.
  def fragment(html) = Nokogiri::HTML5.fragment(html)

  test "the wallet option is suppressed when the nudge holds" do
    html = render_card(nudged: true)

    assert_empty fragment(html).css("[data-auth-solana]"),
                 "a gifted newcomer must not meet a wallet choice they have no reason to make"
  end

  # THE CONTROL. Same partial, same render, nudge off — the option is there.
  # Without it the assertion above passes for a card that lost the button for
  # some entirely different reason.
  test "the wallet option is present when the nudge does not hold" do
    html = render_card(nudged: false)

    assert_equal 1, fragment(html).css("[data-auth-solana]").length
  end

  # THE REMOVAL MUST NOT TAKE ANYTHING ELSE WITH IT. Google and the email field
  # are the other two ways in, and the divider is what keeps the card reading as
  # two groups rather than a list that lost a row.
  test "the rest of the card is untouched by the suppression" do
    nudged = fragment(render_card(nudged: true))
    plain  = fragment(render_card(nudged: false))

    [nudged, plain].each do |card|
      assert_equal 1, card.css("form[action^='/auth/google_oauth2']").length
      assert_equal 1, card.css("input#email").length
      assert_equal 1, card.css("span").select { |s| s.text.strip == "or" }.length
    end
  end
end
