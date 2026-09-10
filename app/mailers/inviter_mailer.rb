class InviterMailer < ApplicationMailer
  layout "branded_mailer"

  # Sent when an invitee submits their first confirmed contest entry.
  # ReferralProgress.mark_entered! triggers this through
  # InviterNotificationJob, which calls #with(invitee:).friend_joined_contest
  # → deliver_now in the background. Inviter is derived from invitee.inviter.
  #
  # Single-shot per invitee: contest_entered is a one-way ratchet, so the
  # email fires exactly once per (inviter, invitee) pair regardless of how
  # many additional entries the invitee submits.
  def friend_joined_contest(invitee:)
    @invitee = invitee
    @inviter = invitee.inviter
    return if @inviter.blank? || @inviter.email.blank?

    # Pre-render the messaging variables so the views stay declarative.
    @invitees_in_contest = @inviter.invitees_in_contest_count
    @target              = 2
    @remaining           = [@target - @invitees_in_contest, 0].max
    @account_url         = account_url
    @banner_url          = Studio::EmailCatalog.resolved_url(:friend_joined_contest)
    @banner_alt          = "Your Friend's In!"

    mail(
      to: @inviter.email,
      subject: subject_line
    )
  end

  private

  def subject_line
    if @remaining.positive?
      "#{@invitee.display_name} just entered a Turf Monster contest 🎉 — bring one more friend"
    else
      "#{@invitee.display_name} just entered a Turf Monster contest 🎉 — your free entry token is on the way"
    end
  end
end
