require "test_helper"

module Studio
  # [unit] /l/<token> is bound to THIS app's database, and the bounce to /signin
  # is what that binding looks like from outside.
  #
  # THE FIELD REPORT. On a desk (worktree) stack, a magic link minted with
  # Studio::Link.create_magic_link redirected to /signin instead of signing the
  # operator in. The link was not expired and not consumed — verified in the row
  # store, 2026-09-09: `live=true consumed=false expires=2026-09-10`.
  #
  # THE CAUSE. It was minted into a different database. A desk owns its own via
  # DATABASE_URL in .env.agent-stack, and nothing in config/ or bin/ loads that
  # file — so a bare `bin/rails runner` in a worktree falls through
  # config/database.yml to the shared turf_monster_development and mints there.
  # Measured on a fresh desk the same day: the same server, in the same second,
  # answered 302 -> /signin for a token minted in the shared database and 200
  # (the interstitial) for one minted in its own. Nothing about the code, the
  # server, the host, the port or the token's own liveness differed between the
  # two clicks — only which database held the row.
  #
  # WHAT THESE TESTS PIN. The engine's LinkConsumption tests already cover the
  # POST door and the decision table behind it (see magic_link_reclick_test.rb
  # for turf's side of that). These cover the GET door at /l/<token> from a
  # SIGNED-OUT browser, which is the door the operator actually walks through
  # and the one that produced the report — and they pin the bounce as INTENDED,
  # so nobody reads the incident as "the redirect is the bug" and softens an
  # unknown token into something that leaks or half-authenticates.
  #
  # A token this database does not hold is exactly what
  # Studio::Link.find_by(token:) saw on that desk: nil. That is the mechanism
  # reproduced, not a stand-in for it — the desk's second database is precisely
  # a place this connection cannot see.
  #
  # The way NOT to hit this is bin/review-link, which mints in-request through
  # /_studio/local_review so the row cannot land anywhere else. Round-tripped in
  # test/integration/desk_review_link_test.rb.
  class DeskLinkDbBindingTest < ActionDispatch::IntegrationTest
    # The reported symptom, pinned. Signed out, on a token this database has
    # never held.
    test "a token this database does not hold bounces to /signin" do
      get link_path(token: "minted-in-another-database")

      assert_redirected_to signin_path
      assert_nil session[Studio.session_key], "an unknown token must not authenticate anyone"
      assert_match(/invalid or has expired/i, flash[:alert].to_s,
                   "the operator is told the link is dead, which is why this reads as a link bug")
    end

    # The contrast that gives the assertion above its meaning: the SAME door,
    # the SAME signed-out browser, a token that differs only in being present
    # here. Without this, "redirects to /signin" could equally be a broken route
    # or a dead controller, and the test would pin nothing about the database.
    test "the same door serves the interstitial for a token this database holds" do
      token = magic_token(email: users(:alex).email, age_attested: true)

      get link_path(token: token)

      assert_response :success
      # The { count: 1 } is load-bearing, not decoration. assert_select reads a
      # bare trailing String as a TEXT equality test on the matched element, not
      # as a failure message — so without a comparison here the message would
      # quietly become the assertion, and this would pin the button's label
      # instead of the form's action.
      assert_select "form[action=?]", link_consume_path(token: token), { count: 1 },
                    "a live token gets the auto-POSTing confirm interstitial, not a redirect"
      assert_nil Studio::Link.find_by(token: token).consumed_at,
                 "and the GET stays inert — only the POST burns it"
    end

    # The bounce must not cost a visitor who IS signed in their session. Same
    # door, same unknown token, session held: the engine's rule is that a dead
    # link never touches the session, and the GET door has to honour it too.
    test "an unknown token at the GET door leaves a held session alone" do
      log_in_as(users(:alex))

      get link_path(token: "minted-in-another-database")

      assert_equal users(:alex).id, session[Studio.session_key],
                   "a link that resolves nowhere must not log out a valid session"
    end
  end
end
