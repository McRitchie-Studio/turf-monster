require "test_helper"

# LinkPreviewBot decides who gets the slim link-preview document instead of the
# full ~1.2 MB app page. A false positive hands a real person a page with no
# app on it, so the human cases matter as much as the bot cases.
class LinkPreviewBotTest < ActiveSupport::TestCase
  BOTS = {
    # Apple LinkPresentation (iMessage), as sent from macOS/iOS Messages.
    "iMessage" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_1) AppleWebKit/601.2.4 " \
                  "(KHTML, like Gecko) Version/9.0.1 Safari/601.2.4 facebookexternalhit/1.1 " \
                  "Facebot Twitterbot/1.0",
    "Facebook" => "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)",
    "Facebot" => "Facebot",
    "X" => "Twitterbot/1.0",
    "Discord" => "Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)",
    "Slack" => "Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)",
    "LinkedIn" => "LinkedInBot/1.0 (compatible; Mozilla/5.0; Apache-HttpClient +http://www.linkedin.com)",
    "WhatsApp" => "WhatsApp/2.23.20.0 A",
    "Telegram" => "TelegramBot (like TwitterBot)",
    "Applebot" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_5) AppleWebKit/605.1.15 " \
                  "(KHTML, like Gecko) Version/13.1.1 Safari/605.1.15 (Applebot/0.1; +http://www.apple.com/go/applebot)",
    "Skype" => "Mozilla/5.0 (Windows NT 6.1; WOW64) SkypeUriPreview Preview/0.5",
    "Reddit" => "Mozilla/5.0 (compatible; redditbot/1.0; +http://www.reddit.com/feedback)",
    "Embedly" => "Mozilla/5.0 (compatible; Embedly/0.2; +http://support.embed.ly/)"
  }.freeze

  HUMANS = {
    "iPhone Safari" => "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 " \
                       "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
    "Chrome" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " \
                "(KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36",
    # In-app browsers of the same companies are people, not unfurlers.
    "Facebook in-app" => "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 " \
                         "(KHTML, like Gecko) Mobile/15E148 [FBAN/FBIOS;FBAV/480.0.0.0]",
    "LinkedIn in-app" => "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 " \
                         "(KHTML, like Gecko) Mobile/15E148 LinkedInApp/9.30",
    "X in-app" => "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 " \
                  "(KHTML, like Gecko) Mobile/15E148 Twitter for iPhone/10.60"
  }.freeze

  BOTS.each do |name, ua|
    test "#{name} preview fetcher is a link-preview bot" do
      assert LinkPreviewBot.match?(ua), "expected #{name} to match: #{ua}"
    end
  end

  HUMANS.each do |name, ua|
    test "#{name} is not a link-preview bot" do
      assert_not LinkPreviewBot.match?(ua), "#{name} must get the full page: #{ua}"
    end
  end

  test "a blank or missing user agent is not a bot" do
    assert_not LinkPreviewBot.match?(nil)
    assert_not LinkPreviewBot.match?("")
    assert_not LinkPreviewBot.match?("   ")
  end

  test "an unknown agent is not a bot" do
    assert_not LinkPreviewBot.match?("curl/8.7.1")
    assert_not LinkPreviewBot.match?("SomeNewCrawler/1.0")
  end
end
