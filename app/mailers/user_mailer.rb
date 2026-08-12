class UserMailer < ApplicationMailer
  # Branded shell for all UserMailer emails.
  layout "branded_mailer"

  # OPSEC-005: email verification challenge. Token is a signed payload
  # (id + email + expiry) generated via Rails.application.message_verifier.
  # The recipient clicks the link → controller verifies the token → sets
  # users.email_verified_at. Tokens are scoped to the email they were
  # issued for; if the user changes email before verifying, the old token
  # no longer verifies.
  def email_verification(user, token, contest: nil)
    @user = user
    @contest = contest
    @verify_url = email_verifications_verify_url(token: token)
    @banner_url = Studio::EmailCatalog.resolved_url(:email_verification)
    @banner_alt = "Verify Your Email"
    mail(to: user.email, subject: "Verify your Turf Monster email")
  end

  # Unified create-or-login magic link. `email` is a raw string (the user may
  # not exist yet). Token is a signed MagicLink payload (email + return_to +
  # jti, 15-min single-use). Clicking the link logs the recipient in or creates
  # their account. Contest-aware copy when the link came from an entry flow.
  def magic_link(email, token, contest: nil)
    @contest = contest
    @email = email
    @magic_url = link_url(token: token) # unified /l/<token> (Studio::LinksController)
    # Admin-managed banner (Studio::EmailImage) with the versioned asset as the
    # fallback until an operator uploads one. Manage at /admin/email_images.
    @banner_url = Studio::EmailCatalog.resolved_url(:magic_link)
    @banner_alt = "Your Magic Link"
    mail(to: email, subject: "🐊🪄 Turf Totals Sign-in Link")
  end

  # Self-custody wallet export (task #11). Token is a signed payload from
  # AccountsController#initiate_wallet_export, valid 30 min. The recipient
  # clicks the link to land on the reveal page (Stage 2 — WalletExportsController#show).
  def wallet_export(user, token)
    @user = user
    @export_url = url_for(controller: "wallet_exports", action: "show", token: token, only_path: false)
    @support_email = "alex@turfmonster.media"
    @banner_url = Studio::EmailCatalog.resolved_url(:wallet_export)
    @banner_alt = "Your Wallet Keys"
    mail(to: user.email, subject: "Your Turf Monster wallet export link")
  end

  # OPSEC-046: notify the OLD email address when a user changes their email.
  # If the change wasn't authorized by the legit user, this gives them an
  # out-of-band channel to notice + take action before the attacker has time
  # to verify the new address.
  def email_change_notification(user, old_email, new_email)
    @user = user
    @old_email = old_email
    @new_email = new_email
    @account_url = account_url
    @banner_url = Studio::EmailCatalog.resolved_url(:email_change_notification)
    @banner_alt = "Heads Up"
    mail(to: old_email, subject: "Your Turf Monster email was changed")
  end

  # Passwordless (Lazarus audit #4): out-of-band confirmation of an email
  # change. Sent TO the CURRENT (pre-change) address — the holder of the
  # existing email authorizes the swap by clicking. Token is a signed
  # message_verifier payload from AccountsController#update, valid 30 min.
  # Mirrors the wallet_export mailer (token → confirm URL).
  def email_change_confirmation(user, current_email, new_email, token)
    @user = user
    @current_email = current_email
    @new_email = new_email
    @confirm_url = confirm_email_change_url(token)
    @banner_url = Studio::EmailCatalog.resolved_url(:email_change_confirmation)
    @banner_alt = "Confirm Your Email"
    mail(to: current_email, subject: "Confirm your Turf Monster email change")
  end
end
