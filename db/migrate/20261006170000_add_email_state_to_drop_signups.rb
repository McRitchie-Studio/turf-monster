# The drop list starts mailing (DropSignupMailer): one confirmation when an
# address joins, one announcement when the slate drops, and a one-click
# unsubscribe in both.
#
#   confirmation_sent_at      claimed BEFORE the confirmation is queued, by a
#                             conditional UPDATE (… WHERE confirmation_sent_at
#                             IS NULL), so a re-submit, a retry or a twin
#                             request can never mail the address twice
#   unsubscribed_at           set by the signed unsubscribe link; a row with it
#                             is never mailed again
#   announcement_delivery_id  the EmailDelivery outbox row the announcement went
#                             out as; notified_at is the claim, this is the
#                             receipt, and /admin/drop_signups/announcement
#                             reads sent/failed/pending through it
#
# Schema only: every column starts NULL, nothing to backfill or run after deploy.
class AddEmailStateToDropSignups < ActiveRecord::Migration[8.1]
  def change
    add_column :drop_signups, :confirmation_sent_at, :datetime
    add_column :drop_signups, :unsubscribed_at, :datetime
    add_reference :drop_signups, :announcement_delivery,
                  foreign_key: { to_table: :email_deliveries, on_delete: :nullify }
  end
end
