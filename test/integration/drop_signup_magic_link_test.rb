require "test_helper"

# [integration] The new-player CTA in the drop emails is a Studio::Link magic
# link into turf's REAL create-or-login flow (/l/:token →
# Studio::LinksController < MagicLinksController). These walk it end to end:
# the account it creates, the attribution it carries, and what an expired link
# degrades to.
class DropSignupMagicLinkTest < ActionDispatch::IntegrationTest
  setup do
    @signup = DropSignup.create!(email: "newbie@example.com", slate_key: NextSlateDrop::SLATE_KEY, source: "tiktok")
  end

  def mint_from_email(kind = :confirmation)
    DropSignupMailer.public_send(kind, @signup).message
    link = Studio::Link.magic_links.where(linkable: @signup).order(:id).last
    url = DropSignupMailer.public_send(kind, @signup).message.text_part.body.to_s[%r{http://\S+/l/\S+}]
    [link, URI.parse(url)]
  end

  test "the emailed link creates the account, verified, signed in, credited to the signup's source" do
    _link, uri = mint_from_email
    assert_equal "reference=tiktok", uri.query

    get "#{uri.path}?#{uri.query}" # the GET: inert confirm page, seeds the reference cookie
    assert_response :success
    post link_consume_path(token: uri.path.split("/").last)

    user = User.find_by(email: "newbie@example.com")
    assert user, "the click created the account"
    assert_equal "tiktok", user.reference
    assert user.email_verified_at.present?, "the click from the inbox proves the address"
    assert_equal user.id, session[Studio.session_key]
  end

  test "attribution still lands when the reference cookie never stuck" do
    link, = mint_from_email
    post link_consume_path(token: link.token) # no GET, so no cookie

    assert_equal "tiktok", User.find_by!(email: "newbie@example.com").reference
  end

  test "the announcement's link lands the new account on the next contest" do
    contest = contests(:one)
    link = nil
    NextContest.stub(:pick, NextContest::Pick.new(contest: contest)) { link, = mint_from_email(:announcement) }
    post link_consume_path(token: link.token)

    assert User.exists?(email: "newbie@example.com")
    assert_equal contest_path(contest.slug), URI.parse(response.location).path
  end

  test "the confirmation's link lives 7 days and the announcement's 48 hours, not the sign-in default" do
    confirmation, = mint_from_email(:confirmation)
    assert_in_delta 7.days.from_now.to_i, confirmation.expires_at.to_i, 60

    announcement = nil
    NextContest.stub(:pick, NextContest::Pick.new(contest: nil)) { announcement, = mint_from_email(:announcement) }
    assert_in_delta 48.hours.from_now.to_i, announcement.expires_at.to_i, 60

    travel(Studio.magic_link_ttl + 1.minute) do
      assert confirmation.reload.live?, "still live well past the sign-in default"
      assert announcement.reload.live?
    end
    assert_equal 15.minutes, Studio.magic_link_ttl, "the app default is untouched"
  end

  test "the confirmation link still signs them up on day 6" do
    link, = mint_from_email
    travel(6.days) { post link_consume_path(token: link.token) }
    assert User.exists?(email: "newbie@example.com")
  end

  test "an expired link falls back to sign-in with the address prefilled" do
    link, = mint_from_email
    travel(DropSignupMailer::LINK_TTL[:confirmation] + 1.minute) do
      get link_path(token: link.token)
      location = URI.parse(response.location)
      assert_equal signin_path, location.path
      assert_equal "newbie@example.com", Rack::Utils.parse_query(location.query)["email"]

      follow_redirect!
      assert_response :success
      assert_select "input#email[value=?]", "newbie@example.com"
    end
    refute User.exists?(email: "newbie@example.com"), "a dead link creates nothing"
  end

  test "an expired link that is not a drop link prefills nothing" do
    token = magic_token(email: "someone@example.com")
    travel(Studio.magic_link_ttl + 1.minute) do
      get link_path(token: token)
      assert_nil Rack::Utils.parse_query(URI.parse(response.location).query)["email"]
    end
  end

  test "with the signup age attestation on, the link sends them to sign-in, address prefilled, no account" do
    ENV["ENABLE_AGE_ATTESTATION"] = "true"
    link, = mint_from_email
    post link_consume_path(token: link.token)

    location = URI.parse(response.location)
    assert_equal signin_path, location.path
    assert_equal "newbie@example.com", Rack::Utils.parse_query(location.query)["email"]
    refute User.exists?(email: "newbie@example.com")
  ensure
    ENV.delete("ENABLE_AGE_ATTESTATION")
  end
end
