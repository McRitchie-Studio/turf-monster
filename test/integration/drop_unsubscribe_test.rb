require "test_helper"

# [integration] The drop emails' one-click unsubscribe: signed token, no login.
class DropUnsubscribeTest < ActionDispatch::IntegrationTest
  setup do
    @signup = DropSignup.create!(email: "fan@example.com", slate_key: NextSlateDrop::SLATE_KEY)
    @token = @signup.unsubscribe_token
  end

  # A mail scanner GETs every link and runs no script. The GET must change
  # nothing; the page's auto-submitting form is what a person's click POSTs.
  test "the GET is inert and renders the auto-submitting form" do
    get drop_unsubscribe_path(token: @token)
    assert_response :success
    assert_nil @signup.reload.unsubscribed_at
    assert_select "form#drop-unsubscribe-form[action=?]", drop_unsubscribe_confirm_path(token: @token)
  end

  test "the POST unsubscribes, with no session" do
    post drop_unsubscribe_confirm_path(token: @token)
    assert_response :success
    assert @signup.reload.unsubscribed_at.present?
    assert_select '[data-test="drop-unsubscribe-done"]'
  end

  # RFC 8058: the mail client POSTs List-Unsubscribe=One-Click to the header URL.
  test "the List-Unsubscribe-Post one-click body works on the same URL" do
    post drop_unsubscribe_path(token: @token), params: { "List-Unsubscribe" => "One-Click" }
    assert_response :success
    assert @signup.reload.unsubscribed?
  end

  test "a signed-in account with an incomplete profile is not bounced to onboarding" do
    user = users(:alex)
    log_in_as(user)
    user.update_column(:username, nil) # after login, which claims a parked username
    get drop_unsubscribe_path(token: @token)
    assert_response :success
  end

  test "an unsubscribed address is never mailed again" do
    post drop_unsubscribe_confirm_path(token: @token)
    refute @signup.reload.deliver_confirmation!
    refute @signup.deliver_announcement!
    assert_equal 0, DropSignup.announceable(NextSlateDrop::SLATE_KEY).count
  end

  test "a tampered or unknown token is a 404 and changes nothing" do
    [@token.sub(/.\z/) { |c| c == "A" ? "B" : "A" }, "preview", "garbage--token"].each do |bad|
      get drop_unsubscribe_path(token: bad)
      assert_response :not_found
      post drop_unsubscribe_confirm_path(token: bad)
      assert_response :not_found
      assert_select '[data-test="drop-unsubscribe-invalid"]'
    end
    assert_nil @signup.reload.unsubscribed_at
  end

  test "an already-unsubscribed link says so on the GET" do
    @signup.unsubscribe!
    get drop_unsubscribe_path(token: @token)
    assert_select '[data-test="drop-unsubscribe-done"]'
  end
end
