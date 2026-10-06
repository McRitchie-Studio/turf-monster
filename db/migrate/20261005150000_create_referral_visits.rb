# Clicks on a trackable link (`?reference=<name>`, a /lp/<slug> landing page,
# or a vanity path like /tiktok), counted on every page.
#
# ONE ROW PER (reference, visitor, day). The visitor is a random first-party
# cookie id, so a refresh or a second page view the same day does not inflate
# the count: the unique index is the dedupe, and the write is a single
# INSERT ... ON CONFLICT DO NOTHING (ReferralVisit.record). Nothing else writes
# here, and no row is ever updated.
#
# The admin report (/admin/referrals) reads clicks from this table and the
# conversions from users.reference (and drop_signups.source, where present).
#
# Schema only: no backfill, nothing to run after deploy.
class CreateReferralVisits < ActiveRecord::Migration[8.1]
  def change
    create_table :referral_visits do |t|
      t.string   :reference,     null: false, limit: 64
      t.string   :visitor_id,    null: false, limit: 36
      t.date     :visited_on,    null: false
      t.string   :landing_path,  limit: 255
      t.string   :utm_source,    limit: 100
      t.string   :utm_medium,    limit: 100
      t.string   :utm_campaign,  limit: 100
      t.datetime :first_seen_at, null: false
    end

    add_index :referral_visits, %i[reference visitor_id visited_on],
              unique: true, name: "index_referral_visits_on_ref_visitor_day"
    add_index :referral_visits, %i[visited_on reference]
  end
end
