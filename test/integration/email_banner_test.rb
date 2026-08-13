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

  # UPDATED, NOT RELAXED. This asserted "magic-link-banner" — the flat JPEG
  # <img> — which was right until this app registered a layered background. The
  # email now draws that artwork as a CSS/VML background with the greeting on
  # top as live HTML, so the flat filename is legitimately gone. Asserting the
  # layered structure is strictly stronger than asserting a filename: it pins
  # the artwork, the Outlook path, and the fact that this is a banner at all.
  test "magic-link email renders the registered banner" do
    mail = UserMailer.magic_link("x@example.com", magic_token(email: "x@example.com"))
    html = (mail.html_part&.body || mail.body).to_s

    assert_includes html, "magic-link-background",
      "the magic-link email should carry this app's registered artwork"
    assert_includes html, "background-size:cover",
      "a layered banner draws the artwork as a background, not an <img>"
    assert_includes html, "v:rect",
      "Outlook renders through Word and needs the VML block or the banner is blank there"
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

    # THE SHARED LAYOUT, asserted here because this app ships no views and no
    # controller for /admin/emails — the whole page is the engine's, so the
    # resolved engine version IS the layout and a stale pin is the only way two
    # apps mounting one shared page can drift apart. They did: on 0.42 this
    # table had five columns (Banner/Email/Subject/Image/Actions) and McRitchie
    # Industries was still drawing it while Studio drew the three-column one.
    # The floor in test/lib/engine_pin_contract_test.rb says which version; this
    # says what the version must actually render, because a floor alone would
    # still pass if the engine changed the table again.
    assert_select "table thead th", count: 3
    assert_select "table thead th", text: /Banner/i
    assert_select "table thead th", text: /Subject/i
    assert_select "table thead th", text: /Email/i
  end

  test "an email's own page previews it" do
    log_in_as(users(:alex))
    get admin_email_path("magic_link")
    assert_response :success

    get admin_email_raw_path("magic_link")
    assert_response :success
    # Same swap as above: the preview renders the real email, so it follows the
    # email from the flat <img> to the layered background.
    assert_includes response.body, "magic-link-background"
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
