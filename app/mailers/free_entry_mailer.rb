# "Your free Turf Monster entry is ready." Sent when an operator presses
# Grant 1 on /admin/free_entries and the mint has CONFIRMED on chain — never
# before, and never for a grant that failed or was refused
# (Admin::FreeEntriesController#grant is the only caller).
#
# It closes the loop a claim-mode landing page opens ("we'll email your free
# entry within a few hours"), so it links to the contest that page was
# promoting, falling back to the featured contest.
#
# House voice (the default transactional from), not the personal one
# EntryGiftMailer borrows: this is the platform confirming a delivery, not a
# friend writing.
class FreeEntryMailer < ApplicationMailer
  layout "branded_mailer"
  helper :landing_pages # claim_lock_time: the moment the confirmation page names

  def ready(user, contest = nil)
    @user    = user
    @contest = contest
    @contest_url = contest ? contest_url(contest.slug) : root_url

    @banner_url = Studio::EmailCatalog.resolved_url(:free_entry_ready)
    @banner_alt = "Your free entry is ready"

    mail(to: user.email, subject: "Your free Turf Monster entry is ready")
  end
end
