require "test_helper"

# [unit] What config/initializers/studio_emails.rb registers on the shared engine
# catalog. No HTTP, no rendering — just the data that replaced the deleted
# app/models/email_catalog.rb.
#
# This is the file that would silently rot: an initializer's registrations are
# invisible until someone opens the admin page or an email goes out with the
# wrong banner. Each assertion below is something that broke a real email if it
# regressed.
class EmailRegistrationTest < ActiveSupport::TestCase
  EXPECTED = {
    "magic_link"                => { type: :transactional, asset: "emails/magic-link-banner.jpg" },
    "email_verification"        => { type: :transactional, asset: "emails/verify-banner.jpg" },
    "wallet_export"             => { type: :transactional, asset: "emails/wallet-export-banner.jpg" },
    "email_change_notification" => { type: :transactional, asset: "emails/email-change-notify-banner.jpg" },
    "email_change_confirmation" => { type: :transactional, asset: "emails/email-change-confirm-banner.jpg" },
    "friend_joined_contest"     => { type: :transactional, asset: "emails/friend-joined-banner.jpg" },
    "contest_winnings"          => { type: :transactional, asset: "emails/winnings-banner.jpg" },
    "newsletter_welcome"        => { type: :marketing,     asset: "emails/welcome-banner.jpg" }
  }.freeze

  test "every email this app sends is registered" do
    assert_equal EXPECTED.keys.sort, Studio::EmailCatalog.keys.sort
  end

  test "each email carries its type and its own banner asset" do
    EXPECTED.each do |key, expected|
      entry = Studio::EmailCatalog.entry(key)
      refute_nil entry, "#{key} is not registered"
      assert_equal expected[:type], entry.type, "#{key} has the wrong type"
      assert_equal expected[:asset], entry.default_asset, "#{key} points at the wrong artwork"
    end
  end

  test "each registered banner file actually exists in this app" do
    # A default_asset naming a file that isn't there renders a broken image in
    # real email while every other assertion here still passes. The seven PNGs
    # were re-cut to JPEG in this change, so the extensions moved.
    EXPECTED.each_value do |expected|
      path = Rails.root.join("app/assets/images", expected[:asset])
      assert path.exist?, "missing banner file: #{expected[:asset]}"
    end
  end

  test "banners are cut to the 1200x600 the mailer renders at" do
    # They ship full-bleed at 600px in a 600px card; 1200x600 is retina-sharp
    # without carrying a 1.7 MB payload into an inbox.
    EXPECTED.each_value do |expected|
      path = Rails.root.join("app/assets/images", expected[:asset])
      assert path.size < 400.kilobytes,
        "#{expected[:asset]} is #{(path.size / 1024.0).round}KB — re-cut it to 1200x600"
    end
  end

  test "every email has a preview builder" do
    EXPECTED.each_key do |key|
      assert Studio::EmailCatalog.entry(key).previewable?,
        "#{key} lost its preview builder"
    end
  end

  test "no email is left on the retired local catalog" do
    refute defined?(::EmailCatalog),
      "app/models/email_catalog.rb should be gone — the engine catalog replaced it"
  end
end
