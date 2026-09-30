# Recognizes link-preview fetchers (the unfurlers behind iMessage, Discord,
# Slack, X, WhatsApp...) by User-Agent, so the application layout can hand them
# a slim document of preview tags instead of the full app page.
#
# WHY: Apple's LinkPresentation, which builds iMessage previews on the sender's
# device, aborts any page whose HTML exceeds 1 MiB (WebKitErrorDomain 102,
# "Frame load interrupted"). Measured 2026-09-30: 1,048,000 bytes previews,
# 1,049,000 fails, and a contest page was 1,224,381 bytes, so no contest link
# (nor the root, which 302s to one) previewed in Messages. Discord has no such
# limit, which is why it kept working.
#
# ALLOW-LIST, ONE PLACE. Only agents named here get the slim page; a person or
# an unknown agent always gets the full page. Each token is a product's own
# fetcher name, not its in-app browser: Facebook's in-app browser sends
# FBAN/FBAV, LinkedIn's sends LinkedInApp, X's sends "Twitter for iPhone", and
# none of those match.
#
# iMessage has no token of its own: LinkPresentation sends an old-Safari UA
# suffixed with "facebookexternalhit/1.1 Facebot Twitterbot/1.0", so it rides
# the Facebook and X tokens.
module LinkPreviewBot
  TOKENS = [
    "facebookexternalhit",    # Facebook, Messenger; also Apple LinkPresentation (iMessage)
    "Facebot",                # Facebook; also iMessage
    "Twitterbot",             # X; also iMessage
    "Discordbot",
    "Slackbot-LinkExpanding",
    "LinkedInBot",
    "WhatsApp/",              # the fetcher sends WhatsApp/<version>
    "TelegramBot",
    "Applebot",               # Siri / Spotlight suggestions
    "SkypeUriPreview",        # Skype and Teams
    "redditbot",
    "Embedly"
  ].freeze

  PATTERN = Regexp.union(TOKENS.map { |token| /#{Regexp.escape(token)}/i }).freeze

  module_function

  def match?(user_agent)
    user_agent.present? && PATTERN.match?(user_agent)
  end
end
