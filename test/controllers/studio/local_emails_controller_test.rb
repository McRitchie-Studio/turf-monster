require "test_helper"

module Studio
  class LocalEmailsControllerTest < ActionDispatch::IntegrationTest
    setup do
      Studio.local_email_capture = true
    end

    # No teardown: test_helper pins capture back OFF before every test.

    test "shows recent local emails with magic-link proof URLs" do
      token = Studio::Link.create_magic_link(email: users(:alex).email, age_attested: true).token
      ::EmailDelivery.deliver(UserMailer, :magic_link, users(:alex).email, token, to: users(:alex).email, contest: contests(:one))

      get studio_local_emails_path

      assert_response :success
      assert_includes response.body, "UserMailer#magic_link"
      assert_includes response.body, "/magic_link/"
      assert_includes response.body, "Capture enabled"
    end

    test "json includes action URLs for agents" do
      token = Studio::Link.create_magic_link(email: users(:alex).email, age_attested: true).token
      ::EmailDelivery.deliver(UserMailer, :magic_link, users(:alex).email, token, to: users(:alex).email, contest: contests(:one))

      get studio_local_emails_path(format: :json)

      assert_response :success
      body = JSON.parse(response.body)
      assert_equal true, body["capture_enabled"]
      assert_equal "UserMailer#magic_link", body["deliveries"].first["email_key"]
      assert_match %r{/magic_link/}, body["deliveries"].first["action_url"]
    end
  end
end
