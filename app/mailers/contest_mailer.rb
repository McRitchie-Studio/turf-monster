class ContestMailer < ApplicationMailer
  include ApplicationHelper
  layout "branded_mailer"

  # Winner-notification email, sent after a contest's on-chain settlement
  # lands (the settle_contest PendingTransaction is confirmed and
  # contest.onchain_settled flips true). Enqueued per winning entry by
  # Contests::WinnerNotifier via WinnerNotificationJob — never sent at grade
  # time, so a winner is only told they won once the payout has actually
  # moved on-chain.
  #
  # `entry` is a winning Entry (payout_cents > 0). The recipient is the
  # entry's user; the notifier guarantees the user has an email before
  # enqueuing (wallet-only winners are skipped upstream).
  def winnings(entry)
    @entry   = entry
    @contest = entry.contest
    @user    = entry.user
    @payout  = dollars(entry.payout_cents / 100.0)
    @rank    = entry.rank
    @contest_url = contest_url(@contest)
    @banner_url = Studio::EmailCatalog.resolved_url(:contest_winnings)
    @banner_alt = "You Won!"

    mail(
      to: @user.email,
      subject: "🏆 You won #{@payout} on Turf Monster!"
    )
  end
end
