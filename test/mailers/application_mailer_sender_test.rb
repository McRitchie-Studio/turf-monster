require "test_helper"

# The sender as config/initializers/studio.rb boots it. studio-engine defaults an
# unset sender to "<app_name> <team@mcritchie.studio>" and ignores the retired
# ses_from:, so an initializer passing only ses_from: would send Turf mail as
# "Turf Monster" (turf-pins-its-mail-sender). Turf's name is pinned through
# resend_from:, the same name ApplicationMailer::RESEND_FROM carries.
class ApplicationMailerSenderTest < ActiveSupport::TestCase
  test "the booted Studio.mailer_from is McRitchie Studio at team@mcritchie.studio" do
    skip "RESEND_MAILER_FROM overrides the booted sender here" if ENV["RESEND_MAILER_FROM"].present?

    assert_equal "McRitchie Studio <team@mcritchie.studio>", Studio.mailer_from
    assert_equal ApplicationMailer::RESEND_FROM, Studio.mailer_from
  end

  test "the initializer passes resend_from:, never only the retired ses_from:" do
    source = Rails.root.join("config/initializers/studio.rb").read
    call = source[/config\.mailer_from = Studio\.mailer_from_for_transport\((.*?)\)/m, 1]

    refute_nil call, "config.mailer_from is no longer set through mailer_from_for_transport"
    assert_includes call, "resend_from:"
  end
end
