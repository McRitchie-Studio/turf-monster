# "Tell me when the slate drops" — an email, with or without an account.
#
# Nothing stored an anonymous email before this: the newsletter join
# (NewsletterController#subscribe) is authed and writes to users. This table is
# the list the /turf-monster-v2 explainer collects for the next slate drop.
#
# `slate_key` names the drop ("nfl-2026-weeks-7-9"), so one table serves every
# future drop, and the unique index is on the PAIR: the same address may ask to
# hear about Weeks 7-9 and, later, Weeks 10-12. `notified_at` stays nil until
# the drop email goes out — no sender exists yet; it lands in its own task.
#
# Schema only: no backfill, nothing to run after deploy.
class CreateDropSignups < ActiveRecord::Migration[8.1]
  def change
    create_table :drop_signups do |t|
      t.string   :email,     null: false
      t.string   :slate_key, null: false
      t.string   :source
      t.string   :ip
      t.string   :user_agent
      # The address is the subscription, not the account: deleting a user
      # keeps the row and clears the link, in the database itself.
      t.references :user, foreign_key: { on_delete: :nullify }
      t.datetime :notified_at
      t.timestamps
    end

    add_index :drop_signups, [:slate_key, :email], unique: true
    add_index :drop_signups, :created_at
  end
end
