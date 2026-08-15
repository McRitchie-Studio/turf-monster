require "test_helper"

# [integration] The newsletter and quests cards on the shared /profile page.
#
# Two things meet here that the engine deliberately keeps apart: the engine owns
# the newsletter row and knows nothing about seeds, and this app owns the seeds
# and the quests and knows nothing about how the row is rendered. The seam
# between them is Studio.after_newsletter_change, and it is the only place a
# subscribe on /profile can pay the welcome bonus.
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

  # THE ORDERING THAT MAKES THE BONUS PAYABLE. The engine computes first_join
  # BEFORE it writes joined_email_list_at; asked afterwards it is always false.
  # This asserts the app's callback receives it true on a first-ever join.
  test "subscribing on the profile page grants the welcome seeds" do
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

  # /account keeps its own path, and the two must not both fire for one join.
  test "the account page still subscribes and still grants" do
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
