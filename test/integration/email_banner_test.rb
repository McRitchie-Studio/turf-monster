require "test_helper"

# [integration] Turf Monster's emails after adopting the shared engine manager.
#
# The app used to carry two half-managers: ::EmailCatalog + Admin::EmailsController
# (all 8 emails, typed, previewable, no banner management) and the engine's
# /admin/email_images (one email, its banner, nothing else). Both are gone. This
# asserts what replaced them — one page, at /admin/emails, that does both — and
# the two things that could silently regress in real email while every page still
# looks fine.
class EmailBannerTest < ActionDispatch::IntegrationTest
  # --- what actually ships in the inbox --------------------------------------

  # The banner is registered as a default_asset pointing at THIS APP's committed
  # artwork, so it must resolve through turf-monster's own asset pipeline — not
  # the engine's. If default_asset only ever resolved gem assets, every one of
  # these emails would silently lose its banner.
  test "each registered email resolves a banner from this app's own assets" do
    %i[magic_link email_verification wallet_export email_change_notification
       email_change_confirmation friend_joined_contest contest_winnings
       newsletter_welcome].each do |key|
      url = Studio::EmailCatalog.resolved_url(key)
      refute_nil url, "#{key} must resolve a banner"
      assert_match(/emails\/.*\.jpg/, url, "#{key} should serve this app's re-cut JPEG banner")
    end
  end

  test "magic-link email renders the registered banner" do
    mail = UserMailer.magic_link("x@example.com", magic_token(email: "x@example.com"))
    html = (mail.html_part&.body || mail.body).to_s

    assert_includes html, "magic-link-banner", "the magic-link email should carry its banner"
  end

  # An operator upload wins over the committed file — the whole point of the
  # inherit-then-own model. Before adoption this app had NO way to do that for
  # seven of its eight emails.
  test "an uploaded banner overrides this app's committed asset" do
    Studio::S3.stub(:upload, ->(**_) { "https://bucket.s3.amazonaws.com/x" }) do
      Studio::S3.stub(:delete, ->(**_) { nil }) do
        Studio::EmailCatalog.store(:contest_winnings, io: StringIO.new("fake-png-bytes"), content_type: "image/png")
      end
    end
    record = Studio::EmailCatalog.record(:contest_winnings)
    assert record.present?
    assert_equal :app, Studio::EmailCatalog.source(:contest_winnings)

    mail = ContestMailer.winnings(entries(:one))
    html = (mail.html_part&.body || mail.body).to_s
    assert_includes html, record.s3_key, "the uploaded banner must win over the committed asset"
  end

  # --- the catalog itself ----------------------------------------------------

  test "all eight emails are registered, with the newsletter typed marketing" do
    keys = Studio::EmailCatalog.keys

    %w[magic_link email_verification wallet_export email_change_notification
       email_change_confirmation friend_joined_contest contest_winnings
       newsletter_welcome].each { |k| assert_includes keys, k }

    assert_equal :marketing, Studio::EmailCatalog.type("newsletter_welcome")
    assert_equal :transactional, Studio::EmailCatalog.type("magic_link")
  end

  test "every email carries a preview builder" do
    Studio::EmailCatalog.entries.each do |entry|
      assert entry.previewable?, "#{entry.key} lost its preview builder in the move"
    end
  end

  # --- the page --------------------------------------------------------------

  test "the shared emails page is admin-only and lists every email" do
    get admin_emails_path
    assert_redirected_to signin_path # turf-monster signs in at /signin

    log_in_as(users(:alex))
    get admin_emails_path
    assert_response :success
    assert_select "tbody tr", count: Studio::EmailCatalog.entries.size
  end

  test "an email's own page previews it" do
    log_in_as(users(:alex))
    get admin_email_path("magic_link")
    assert_response :success

    get admin_email_raw_path("magic_link")
    assert_response :success
    assert_includes response.body, "magic-link-banner"
  end

  # REGRESSION GUARD. turf-monster's own routes.rb used to define admin_emails
  # and admin_email; the engine page was opt-in ONLY to avoid that collision.
  # Those routes are deleted, so these helpers must now resolve to the ENGINE's
  # controller. If someone re-adds a local admin email route, this goes red.
  test "the emails routes belong to the engine now" do
    route = Rails.application.routes.routes.find { |r| r.name == "admin_emails" }
    assert_equal "studio/emails", route.defaults[:controller],
      "the shared engine page must own /admin/emails"
  end

  # The engine's branded_mailer is app-name-aware through Studio.app_name; the
  # local fork differed only by a hardcoded 'Turf Monster' and a comment.
  test "no local branded_mailer fork shadows the engine layout" do
    refute File.exist?(Rails.root.join("app/views/layouts/branded_mailer.html.erb")),
      "the engine's layout is the one source; a fork drifts silently"

    mail = UserMailer.magic_link("x@example.com", magic_token(email: "x@example.com"))
    assert_includes (mail.html_part&.body || mail.body).to_s, "Turf Monster",
      "the shared layout must still render this app's name"
  end
end
