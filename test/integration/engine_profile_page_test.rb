require "test_helper"

# [integration] The engine's /profile page, RENDERED IN THIS APP.
#
# WHY THIS EXISTS SEPARATELY from the engine's own suite. The engine tests that
# the page renders against a stub user in its dummy app. What it cannot test is
# whether it renders against THIS app's User, THIS app's layout, and THIS app's
# initializer — and every one of those has bitten before. This app forks
# layouts/_navbar, components/_user_nav and studio/modals/_host, any of which
# shadows the engine's copy, and it declares its own profile_sections.
#
# The bump from 0.47.1 to 0.52 crossed five minors. "The gem resolved" is not the
# same claim as "the page works here".
class EngineProfilePageTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:alex)
  end

  # THE APP'S REAL SIGN-IN, driven end to end. This app has no test-only login
  # route, and a session here needs BOTH session[:user_id] and
  # session[:session_token] (OPSEC-045's verify_session_token compares the cookie
  # token to the user's on every request), which no integration test can set by
  # hand. So this walks the magic link: the engine mints it, the GET lands on the
  # confirm page, the POST consumes it.
  #
  # IT ASSERTS THAT IT WORKED, deliberately. The first version of this helper was
  # `post test_sign_in_path(user) if respond_to?(:test_sign_in_path)` — a route
  # this app does not have, so `respond_to?` silently skipped the whole thing and
  # every request below ran signed OUT. A setup step that can quietly do nothing
  # is worse than one that fails.
  def sign_in_as(user)
    link = Studio::Link.create_magic_link(email: user.email, return_to: "/", ttl: 1.hour)
    get "/l/#{link.token}"
    post "/l/#{link.token}"

    get "/account"
    assert_response :success,
      "sign-in did not take — every assertion below would have run signed out"
  end

  test "the profile page renders for a signed-in account" do
    sign_in_as(@user)
    get "/profile"

    # A redirect here means authentication, which is a different failure from a
    # 500 — name them apart so the message is actionable.
    assert_response :success, "/profile did not render in this app (status #{response.status})"

    # THE EMAIL, not the display name. display_name walks a chain
    # (username → name → first_name → email prefix) and this app's magic-link
    # consumption resolves the account by ADDRESS, so the two can legitimately
    # disagree about which name is current — the first version of this assertion
    # expected the fixture's name and got the resolved account's. The address is
    # what the link was minted for, so it is the unambiguous thing to assert.
    assert_includes response.body, @user.email,
                    "the identity header did not render the signed-in account"
    assert_includes response.body, "data-studio-identity-full",
                    "the engine's identity card did not render in this app"
  end

  test "the edit page renders for a signed-in account" do
    sign_in_as(@user)
    get "/profile/edit"

    assert_response :success, "/profile/edit did not render in this app (status #{response.status})"
    assert_includes response.body, 'name="profile[first_name]"'
  end

  # THE HOLD-BACK IS GONE, and that is the point rather than an omission. This
  # test used to assert the newsletter row was ABSENT: the engine's row writes
  # joined_email_list_at directly, this app's 25-seed bonus is gated on that
  # column being nil, so subscribing here would have made the bonus unclaimable
  # forever.
  #
  # Studio.after_newsletter_change (engine 0.53.0) closed that — the grant now
  # runs from the callback in config/initializers/studio.rb — so the row belongs
  # here. What the row does WITH the seeds is asserted in
  # test/integration/profile_newsletter_quests_test.rb; this only pins that it
  # renders, so a future hold-back cannot creep back in unnoticed.
  test "the newsletter row renders on the profile page" do
    sign_in_as(@user)
    get "/profile"

    assert_response :success
    assert_includes response.body, 'data-profile-section="newsletter"',
      "the row was held back only while a subscribe here burned the seeds bonus; the callback closed that"
  end

  # The hold-back must remove ONE row, not freeze the page. Composed against
  # Studio.default_profile_sections, so a row the engine adds later still arrives.
  # The DECLARATION, asserted without a request. The lambda ignores the view — it
  # composes against Studio.default_profile_sections — so calling it directly is
  # the honest test of what this app declares. (Building a view_context by hand
  # here raises: this app's current_user reads session, and a bare controller has
  # no request.) The RENDERED consequence is the test above.
  #
  # It once asserted a row REMOVED; it now asserts one ADDED. What has not changed
  # is the property worth keeping: this app composes against the engine's
  # defaults rather than listing rows, so a row the engine adds later arrives here
  # automatically instead of being silently dropped.
  def test_the_app_adds_its_own_row_without_freezing_the_engines
    declared = Studio.profile_sections.call(nil).map { |section| section[:key].to_sym }
    defaults = Studio.default_profile_sections.map { |section| section[:key].to_sym }

    assert_equal defaults + [:quests], declared,
                 "expected the engine's defaults IN ORDER plus this app's quests row — a literal " \
                 "list here would silently drop whatever the engine adds next"
  end

  # /account is UNTOUCHED by this bump. The migration plan is to stand /profile up
  # beside it and move rows across deliberately; a bump that quietly changed
  # /account would be the opposite of that.
  test "the account page still renders" do
    sign_in_as(@user)
    get "/account"

    assert_response :success, "/account regressed on the engine bump"
  end
end
