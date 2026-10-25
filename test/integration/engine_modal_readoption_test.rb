require "test_helper"

# [component] Turf renders studio-engine's modal cards where it used to carry its
# own copies (turf-readopts-engine-modals, studio-engine 0.114.0).
#
# Nine local cards were deleted: the newsletter five, username, birthday,
# rate-limit-general and email-change-pending. 0.114.0 gave the engine blocks the
# locals those copies existed for (a store, a JSON submit, consent, success and
# goodbye cards, a progress pill, a locked card, a countdown, close actions and
# a message slot). The test it replaces, engine_modal_readoption_gaps_test, read
# the engine for each missing local and went red on the bump that shipped them.
#
# WHAT A PAGE CANNOT SHOW, AND THIS DOES. An engine card and a local copy can
# render identical markup, which is how forks survive unnoticed. So the deletion
# is asserted on disk, and the render is asserted by the engine's own fingerprints
# (studioNewsletterModal, studioModalCountdown, data-username-locked) carrying this
# app's ids, routes and copy.
class EngineModalReadoptionTest < ActionDispatch::IntegrationTest
  DELETED = %w[
    newsletter_email newsletter_subscribe newsletter_success
    unsubscribe_confirm unsubscribe_goodbye
    username birthday rate_limit_general email_change_pending
  ].freeze

  setup do
    @user = users(:alex)
    log_in_as(@user)
    get "/account"
    assert_response :success
    @body = response.body
  end

  def card(id)
    # The engine newsletter cards open with `current()?.id`, the layout's own
    # registrations with `current().id`; either is a registration of +id+.
    start = @body.index(/<template x-if="\$store\.modals\.current\(\)\??\.id === '#{Regexp.escape(id)}'">/)
    assert start, "no registration for #{id} on /account"
    @body[start, @body.index("</template>", start) - start]
  end

  test "the nine local copies are gone from disk" do
    DELETED.each do |name|
      path = Rails.root.join("app/views/modals/_#{name}.html.erb")
      assert_not File.exist?(path), "#{path.basename} is back; the engine renders that card now"
    end
  end

  test "each newsletter card is the engine's, under this app's id, store and routes" do
    { "newsletter-subscribe" => newsletter_subscribe_path,
      "newsletter-email"     => newsletter_subscribe_path,
      "unsubscribe-confirm"  => newsletter_unsubscribe_path }.each do |id, url|
      html = card(id)
      assert_includes html, "studioNewsletterModal(", "#{id} must mount the engine scope"
      assert_includes html, "url: '#{url}'", "#{id} must post to this app's route"
      assert_includes html, "store: 'modals'"
      assert_includes html, "fetcher: 'authedFetch'", "#{id} must keep authedFetch's 401 and 429 cards"
      assert_includes html, "event: 'newsletter-state-changed'"
    end
    assert_includes card("unsubscribe-confirm"), "method: 'POST'"
    assert_includes card("newsletter-subscribe"), "nextId: 'newsletter-success'"
    assert_includes card("unsubscribe-confirm"), "nextId: 'unsubscribe-goodbye'"
    assert_includes card("newsletter-subscribe"), "requiresConsent: true"
  end

  test "the newsletter beats keep this app's copy and next step" do
    assert_includes card("newsletter-subscribe"), "25 seeds for joining"
    assert_includes card("newsletter-email"), "Join &amp; Claim 25 Seeds"
    success = card("newsletter-success")
    assert_includes success, "Subscribed!"
    assert_includes success, "(props.seeds_earned || 0) > 0"
    assert_includes card("unsubscribe-goodbye"), "Change your mind anytime from your account."
  end

  test "the rate-limit card is the engine error card, counting the 429's wait down" do
    html = card("rate-limit-general")
    assert_includes html, "studioModalCountdown({ seconds: ($store.modals.current().props.secondsLeft)"
    assert_includes html, "autoClose: true"
    assert_includes html, "Easy there"
    assert_match(/@click="\$store\.modals\.close\(\)"[^>]*>\s*Dismiss/, html)
  end

  test "the email-change card is the engine success card with both addresses in its message" do
    html = card("email-change-pending")
    assert_includes html, 'x-text="$store.modals.current().props.currentEmail"'
    assert_includes html, 'x-text="$store.modals.current().props.newEmail"'
    assert_match(/@click="\$store\.modals\.close\(\)"[^>]*>Got it/, html)
  end

  test "the birthday card is the engine block carrying the chain pill" do
    html = card("birthday")
    assert_includes html, 'x-data="birthdayModal({'
    assert_operator html.index("rounded-full bg-primary"), :<, html.index("Your birthday"),
      "the 2-of-3 pill must render above the card's title"
  end

  test "the username card is the engine block" do
    html = card("username")
    rename = html.include?("data-username-locked") || html.include?("tmUsernameFinalize")
    assert rename, "the username card must render the engine block, locked or open"
  end
end
