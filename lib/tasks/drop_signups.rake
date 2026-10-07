# One-time backfill: the "You're on the list" confirmation for every drop
# signup that joined before the email existed (confirmation_sent_at blank, not
# unsubscribed). Runs once as the drop-signup-emails deploy's post_deploy_cmd.
#
# Safe to rerun: each row goes through DropSignup#deliver_confirmation!, the
# same atomic claim the signup form uses, so an address already confirmed (or
# confirmed by a concurrent run) is skipped and nobody is mailed twice.
#
#   bin/rails drop_signups:send_missing_confirmations
namespace :drop_signups do
  desc "Queue the drop confirmation for every signup that never got one (idempotent)"
  task send_missing_confirmations: :environment do
    result = DropSignup.send_missing_confirmations!
    puts "drop_signups:send_missing_confirmations queued=#{result[:queued]} " \
         "skipped=#{result[:skipped]} failed=#{result[:failed]}"
  end
end
