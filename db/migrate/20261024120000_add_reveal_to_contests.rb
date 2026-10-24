# A coming-soon contest reveals itself (Contest::Reveal).
#
# `reveal_at` is when Contests::RevealSweepJob turns `coming_soon` off;
# `coming_soon_hold` is the operator's deliberate "advertised, not open yet",
# which the sweep never overrides; `coming_soon_alerted_at` records the one
# alert raised for a contest still coming soon within a day of its lock.
#
# Safe on a live table: two nullable columns with no default and one boolean
# with a constant default (a catalogue-only change on PostgreSQL 11+). No
# constraint and NO BACKFILL: every existing contest reads `reveal_at` nil,
# which the sweep treats as "no scheduled reveal" (see Contest::Reveal for
# why a legacy row is left alone rather than given a computed date).
class AddRevealToContests < ActiveRecord::Migration[8.1]
  def up
    add_column :contests, :reveal_at, :datetime, if_not_exists: true
    add_column :contests, :coming_soon_hold, :boolean, default: false, null: false, if_not_exists: true
    add_column :contests, :coming_soon_alerted_at, :datetime, if_not_exists: true
  end

  def down
    remove_column :contests, :coming_soon_alerted_at, if_exists: true
    remove_column :contests, :coming_soon_hold, if_exists: true
    remove_column :contests, :reveal_at, if_exists: true
  end
end
