require "test_helper"

# [unit] NewsletterModalHelper — the locals that make studio-engine's newsletter
# cards (studio/profiles/_newsletter_modals, 0.114.0) this app's five.
#
# Every value here is one an opener or a listener elsewhere depends on by
# string: the ids (the /account and /profile row, the gear sidebar, the quest
# factory, the style guide), the routes and their verb (config/routes.rb draws
# both as POST), the fetcher (authedFetch's 401 and 429 cards) and the event
# (the newsletter-state controller and the seeds listener). A typo in any one
# renders a card that looks right and fails on the press that matters.
class NewsletterModalHelperTest < ActionView::TestCase
  include NewsletterModalHelper

  attr_accessor :current_user

  setup { self.current_user = users(:alex) }

  test "the cards answer to this app's host store and post JSON to this app's routes" do
    locals = newsletter_modal_locals

    assert_equal "modals", locals[:modal_store]
    assert_equal :json, locals[:submit_mode]
    assert_equal newsletter_subscribe_path, locals[:subscribe_url]
    assert_equal newsletter_unsubscribe_path, locals[:unsubscribe_url]
    assert_equal "POST", locals[:unsubscribe_method], "the unsubscribe route is drawn as POST"
    assert_equal "authedFetch", locals[:fetcher]
    assert_equal "newsletter-state-changed", locals[:changed_event]
    assert_equal current_user, locals[:user]
  end

  test "all five cards are on, under the ids every opener already uses" do
    ids = newsletter_modal_locals.values_at(:subscribe_card, :email_card, :success_card,
                                            :unsubscribe_card, :goodbye_card).map { |card| card[:id] }

    assert_equal %w[newsletter-subscribe newsletter-email newsletter-success
                    unsubscribe-confirm unsubscribe-goodbye], ids
  end

  test "the success card carries this app's next step" do
    assert_equal "modals/newsletter_success_next", newsletter_modal_locals.dig(:success_card, :partial)
  end
end
