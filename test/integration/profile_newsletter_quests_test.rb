require "test_helper"

# [integration] The newsletter and quests cards on the shared /profile page.
#
# TWO PATHS REACH THE SAME SUBSCRIPTION, and it is worth being exact about which
# one the UI uses, because they pay the seeds differently.
#
#   THE UI PATH. This app replaces the engine's newsletter row with its own, and
#   that card opens this app's modals, which POST to newsletter_subscribe_path —
#   this app's NewsletterController. The seeds are granted there, directly. The
#   engine is not involved in the write at all.
#
#   THE ENGINE PATH. POST /profile/newsletter still exists and still works; it
#   fires Studio.after_newsletter_change, which this app wires to the same
#   NewsletterSeedGrant. Nothing in the UI calls it today.
#
# THE CALLBACK IS THEREFORE A SAFETY NET RATHER THAN THE MECHANISM, and it is
# kept deliberately: the engine route is public, the engine may grow its own UI
# for it, and a subscribe that reached it WITHOUT the callback would set
# joined_email_list_at, grant nothing, and burn first_newsletter_join? forever —
# the exact bug the row was held back for. The tests below cover both paths and
# say which is which.
class ProfileNewsletterQuestsTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:alex)
  end

  # The app's real sign-in, driven end to end — this app has no test-only login
  # route, and a session needs BOTH session[:user_id] and session[:session_token]
  # (verify_session_token compares the cookie token on every request). It ASSERTS
  # it worked: a setup step that can quietly do nothing would leave every
  # assertion below running signed out.
  def sign_in_as(user)
    link = Studio::Link.create_magic_link(email: user.email, return_to: "/", ttl: 1.hour)
    get "/l/#{link.token}"
    post "/l/#{link.token}"

    get "/account"
    assert_response :success, "sign-in did not take — every assertion below would run signed out"
  end

  # --- the rows render ---------------------------------------------------------

  test "the newsletter row is back on the profile page" do
    sign_in_as(@user)
    get "/profile"

    assert_response :success
    assert_includes response.body, 'data-profile-section="newsletter"',
      "the row was held back while a subscribe here burned the seeds bonus; the callback closed that"
  end

  # THIS APP'S ROW, NOT THE ENGINE'S. The engine ships a plain form and a confirm
  # dialog — right for an app with no rewards, wrong here, where joining is worth
  # 25 seeds and leaving costs them. The replacement is what makes /profile open
  # the same five-modal flow /account has walked people through since the quest
  # system shipped.
  test "the newsletter row opens this app's modal flow, not the engine's" do
    sign_in_as(@user)
    get "/profile"

    assert_includes response.body, "$store.modals.open('newsletter-subscribe')",
      "the card must open THIS app's subscribe modal on the shared host"
    refute_includes response.body, "profileModals.open('newsletter-unsubscribe')",
      "the engine's own confirm dialog must not be what /profile offers here"
  end

  # Replaced by KEY, so it keeps the engine's POSITION rather than being shuffled
  # to the end of the page.
  test "the replacement keeps the engine's row order" do
    keys = Studio.profile_sections.call(nil).map { |s| s[:key].to_sym }
    defaults = Studio.default_profile_sections.map { |s| s[:key].to_sym }

    # POSITION, not the whole list. The claim is that swapping the newsletter row
    # by KEY leaves it where the engine put it — so it is asserted as an INDEX
    # match against the defaults, which stays true as this app appends more rows
    # (the wallet and referral rows broke the literal version of this).
    assert_equal defaults.index(:newsletter), keys.index(:newsletter),
                 "the replacement was appended instead of swapped in place"
    assert_equal defaults, keys.first(defaults.length),
                 "the engine's rows must all still be here, in order"
    assert_equal "accounts/newsletter_section",
                 Studio.profile_sections.call(nil).find { |s| s[:key] == :newsletter }[:partial]
  end

  # ONE IMPLEMENTATION, TWO CALL SITES. The card was extracted from /account so the
  # two pages cannot drift on copy, states, or which modal a button opens.
  test "the account page renders the same card" do
    sign_in_as(@user)
    get "/account"

    assert_response :success
    assert_includes response.body, "$store.modals.open('newsletter-subscribe')"
  end

  # The engine has no quests concept by design — seeds do not belong in a gem four
  # other apps install. This is a HOST row naming a HOST partial, which is what
  # the registry is for.
  test "the quests card renders from this app's own partial" do
    sign_in_as(@user)
    get "/profile"

    assert_response :success
    assert_includes response.body, 'data-profile-section="quests"'
    assert_includes response.body, "Change username", "the quests partial itself did not render"
    assert_includes response.body, "Invite friends"
  end

  # --- the seam ----------------------------------------------------------------

  # --- the ENGINE path (the safety net, not what the UI calls) -----------------
  #
  # THE ORDERING THAT MAKES THE BONUS PAYABLE. The engine computes first_join
  # BEFORE it writes joined_email_list_at; asked afterwards it is always false.
  # This asserts the app's callback receives it true on a first-ever join.
  test "a subscribe through the engine route grants the welcome seeds" do
    sign_in_as(@user)
    @user.update!(joined_email_list_at: nil, left_email_list_at: nil)

    granted = []
    NewsletterSeedGrant.stub(:call, ->(user) { granted << user.id; nil }) do
      post "/profile/newsletter"
    end

    assert_response :redirect
    assert_equal [@user.id], granted, "a first-ever join on /profile must pay the bonus"
    assert @user.reload.subscribed_to_newsletter?
  end

  # A REJOIN must not re-pay. The engine reports first_join false because the
  # account has joined before, and the on-chain PDA would refuse anyway — but the
  # app must not even ask.
  test "rejoining on the profile page does not re-grant" do
    sign_in_as(@user)
    @user.update!(joined_email_list_at: 3.days.ago, left_email_list_at: 2.days.ago)

    granted = []
    NewsletterSeedGrant.stub(:call, ->(user) { granted << user.id; nil }) do
      post "/profile/newsletter"
    end

    assert_empty granted, "this account has joined before — paying again is what the guard exists to stop"
    assert @user.reload.subscribed_to_newsletter?
  end

  test "unsubscribing on the profile page grants nothing" do
    sign_in_as(@user)
    @user.update!(joined_email_list_at: 2.days.ago, left_email_list_at: nil)

    granted = []
    NewsletterSeedGrant.stub(:call, ->(user) { granted << user.id; nil }) do
      delete "/profile/newsletter"
    end

    assert_empty granted
    refute @user.reload.subscribed_to_newsletter?
  end

  # THE SUBSCRIPTION IS THE DURABLE FACT. The grant goes over RPC to a chain that
  # is sometimes unreachable; a failed bonus must never cost someone their place
  # on the mailing list. The engine rescues the callback, and this proves it holds
  # through THIS app's callback rather than trusting the engine's own test.
  test "a failing seed grant does not cost the subscription" do
    sign_in_as(@user)
    @user.update!(joined_email_list_at: nil, left_email_list_at: nil)

    NewsletterSeedGrant.stub(:call, ->(_user) { raise "chain unreachable" }) do
      post "/profile/newsletter"
    end

    assert @user.reload.subscribed_to_newsletter?,
           "the grant blew up and took the subscription with it"
  end

  # --- the UI path (what the cards on BOTH pages actually post to) -------------
  #
  # Both cards open this app's modals, which POST here. This is the path a person
  # actually takes, from /account and from /profile alike.
  test "the app's own subscribe endpoint grants — the path both cards use" do
    sign_in_as(@user)
    @user.update!(joined_email_list_at: nil, left_email_list_at: nil)

    granted = []
    NewsletterSeedGrant.stub(:call, ->(user) { granted << user.id; nil }) do
      post "/account/newsletter/subscribe"
    end

    assert_equal [@user.id], granted, "/account must keep paying its own way"
    assert @user.reload.subscribed_to_newsletter?
  end
end
