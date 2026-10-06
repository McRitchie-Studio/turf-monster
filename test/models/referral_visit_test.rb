require "test_helper"

# [unit] ReferralVisit: one row per visitor per reference per day, bots and
# non-page requests skipped, references normalized, and a failed write that
# never raises.
class ReferralVisitTest < ActiveSupport::TestCase
  VISITOR = "0b6f1c1e-8a7d-4f62-9a55-2a3c0d9e7b11".freeze
  OTHER   = "5d2e9b44-1c3f-4b7a-8e60-7f1a2b3c4d5e".freeze
  BROWSER = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15".freeze
  TIKTOK_IN_APP = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) " \
                  "Mobile/15E148 musical_ly_35.1.0 JsSdk/2.0 NetType/WIFI Channel/App Store ByteLocale/en Region/US " \
                  "RevealType/Dialog isDarkMode/0 WKWebView/1 BytedanceWebview/d8a21c6 FalconTag/".freeze

  def record(reference: "tiktok", visitor: VISITOR, at: Time.zone.parse("2026-10-05 12:00"), **rest)
    ReferralVisit.record(reference: reference, visitor_id: visitor, path: "/", at: at, **rest)
  end

  # --- dedupe ----------------------------------------------------------------

  test "one row per visitor per reference per day" do
    assert_difference "ReferralVisit.count", 1 do
      record
      record(at: Time.zone.parse("2026-10-05 18:00"))
    end
  end

  test "a new day, a new visitor, or a new reference each count" do
    assert_difference "ReferralVisit.count", 3 do
      record
      record(at: Time.zone.parse("2026-10-06 09:00"))
      record(visitor: OTHER)
    end
    assert_difference("ReferralVisit.count", 1) { record(reference: "tiktok-bio") }
  end

  test "the first visit of the day keeps its landing path and time" do
    record(at: Time.zone.parse("2026-10-05 08:00"))
    ReferralVisit.record(reference: "tiktok", visitor_id: VISITOR, path: "/contests", at: Time.zone.parse("2026-10-05 09:00"))

    row = ReferralVisit.sole
    assert_equal "/", row.landing_path
    assert_equal Time.zone.parse("2026-10-05 08:00"), row.first_seen_at
    assert_equal Date.new(2026, 10, 5), row.visited_on
  end

  # --- normalization ---------------------------------------------------------

  test "references are stripped, downcased and cut to 64 characters" do
    assert_equal "tiktok", ReferralVisit.normalize_reference("  TikTok ")
    assert_equal 64, ReferralVisit.normalize_reference("A" * 100).length
    assert_nil ReferralVisit.normalize_reference("   ")
    assert_nil ReferralVisit.normalize_reference(nil)
  end

  test "TikTok and tiktok land in one row" do
    assert_difference("ReferralVisit.count", 1) do
      record(reference: "TikTok")
      record(reference: "tiktok ")
    end
    assert_equal "tiktok", ReferralVisit.sole.reference
  end

  test "UTM values are kept, lowercased and capped" do
    record(utm: { "utm_source" => "TikTok", "utm_medium" => "bio", "utm_campaign" => "x" * 200, "other" => "drop" })
    row = ReferralVisit.sole
    assert_equal "tiktok", row.utm_source
    assert_equal "bio", row.utm_medium
    assert_equal 100, row.utm_campaign.length
  end

  test "nothing to record without a reference or a visitor" do
    assert_no_difference "ReferralVisit.count" do
      assert_equal false, record(reference: " ")
      assert_equal false, record(visitor: nil)
    end
  end

  # --- never breaks a page ---------------------------------------------------

  test "a database error is swallowed and answered with false" do
    ReferralVisit.stub(:insert, ->(*) { raise ActiveRecord::ConnectionNotEstablished, "db down" }) do
      assert_nothing_raised { assert_equal false, record }
    end
  end

  # --- which requests count --------------------------------------------------

  def trackable?(method: "GET", path: "/", user_agent: BROWSER, html: true, **rest)
    ReferralVisit.trackable_request?(method: method, path: path, user_agent: user_agent, html: html, **rest)
  end

  test "a person's GET for a page counts, the TikTok in-app browser included" do
    assert trackable?
    assert trackable?(user_agent: TIKTOK_IN_APP)
  end

  test "link unfurlers and crawlers do not count" do
    [
      "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)",
      "Twitterbot/1.0",
      "Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)",
      "Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)",
      "Mozilla/5.0 (Linux; Android 5.0) AppleWebKit/537.36 (KHTML, like Gecko) Mobile Safari/537.36 (compatible; Bytespider; spider-feedback@bytedance.com)",
      "Mozilla/5.0 (compatible; TikTokBot/1.0)",
      "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
      "curl/8.4.0",
      ""
    ].each { |ua| refute trackable?(user_agent: ua), "#{ua.inspect} should not count" }
  end

  test "HEAD, POST, XHR, prefetch and non-HTML requests do not count" do
    refute trackable?(method: "HEAD")
    refute trackable?(method: "POST")
    refute trackable?(xhr: true)
    refute trackable?(prefetch: true)
    refute trackable?(html: false)
  end

  test "admin, API, asset and engine paths do not count" do
    %w[/admin /admin/referrals /api/v1/contests /assets/app.css /cable /_studio/local_review /rails/active_storage/x].each do |path|
      refute trackable?(path: path), "#{path} should not count"
    end
    assert trackable?(path: "/administrators-guide"), "a prefix match must stop at a path segment"
    assert trackable?(path: "/contests/week-7")
  end

  test "paths that carry a bearer token do not count" do
    %w[
      /l/abc123 /i/abc123 /magic_link/abc123 /email_verification/abc123
      /account/wallet/export/abc123 /account/email/confirm/abc123
    ].each { |path| refute trackable?(path: path), "#{path} should not count" }
    assert trackable?(path: "/account"), "the account page itself carries no token"
    assert trackable?(path: "/lp/launch"), "/l/ must not swallow /lp/"
  end

  # --- retention ---------------------------------------------------------------

  test "prune removes rows past the retention window and nothing newer" do
    today = Date.new(2026, 10, 5)
    cutoff = today - ReferralVisit::RETENTION
    record(at: (cutoff - 1).to_time.change(hour: 10), visitor: "00000000-0000-4000-8000-000000000001")
    record(at: cutoff.to_time.change(hour: 10), visitor: "00000000-0000-4000-8000-000000000002")
    record(at: today.to_time.change(hour: 10), visitor: "00000000-0000-4000-8000-000000000003")

    assert_equal 1, ReferralVisit.prune(today: today)
    assert_equal [cutoff, today], ReferralVisit.order(:visited_on).pluck(:visited_on)
  end
end
