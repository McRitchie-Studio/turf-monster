class NewsletterMailer < ApplicationMailer
  layout "branded_mailer"

  # Email type: MARKETING (explicit opt-in welcome, sent once on the user's first
  # newsletter subscription). Includes a manage-preferences link per best
  # practice. NOTE: the formal one-click unsubscribe framework moves into the
  # shared studio-engine email framework (Phase 2); for now the preferences link
  # points at the account page.
  def welcome(user)
    @user        = user
    @account_url = account_url
    @cta_url     = root_url
    @banner_url  = Studio::EmailCatalog.resolved_url(:newsletter_welcome)
    @banner_alt  = "You're in! — Turf Monster newsletter"
    mail(to: user.email, from: marketing_from, subject: "Welcome to the Turf Monster newsletter 🐊")
  end
end
