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

  # THE HOLD-BACK, asserted rather than trusted to a comment. The engine ships a
  # newsletter row that writes joined_email_list_at directly; this app's 25-seed
  # welcome bonus is gated on that column being nil, so the row appearing here
  # would silently make the bonus unclaimable. config/initializers/studio.rb
  # rejects it — and this is what notices if that line is ever dropped.
  test "the newsletter row is held back from the profile page" do
    sign_in_as(@user)
    get "/profile"

    assert_response :success
    refute_includes response.body, 'data-profile-section="newsletter"',
      "the engine's newsletter row reached /profile — subscribing there sets " \
      "joined_email_list_at without granting seeds, which burns first_newsletter_join? forever"
  end

  # The hold-back must remove ONE row, not freeze the page. Composed against
  # Studio.default_profile_sections, so a row the engine adds later still arrives.
  # The DECLARATION, asserted without a request. The lambda ignores the view — it
  # composes against Studio.default_profile_sections — so calling it directly is
  # the honest test of what this app declares. (Building a view_context by hand
  # here raises: this app's current_user reads session, and a bare controller has
  # no request.) The RENDERED consequence is the test above.
  def test_holding_one_row_back_does_not_freeze_the_rest_of_the_page
    declared = Studio.profile_sections.call(nil).map { |section| section[:key].to_sym }

    refute_includes declared, :newsletter
    assert_equal Studio.default_profile_sections.length - 1, declared.length,
                 "the hold-back must remove exactly ONE row — this app composes against the " \
                 "engine's defaults so a row added later still arrives here automatically"
    assert_includes declared, :name, "the rest of the page must be untouched"
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
