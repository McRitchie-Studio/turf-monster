# Wire projections to their capturing snapshot, and record the market basis.
#
# - market_snapshot_id: every projection now belongs_to the run that wrote it.
#   Nullable (never backfilled) so pre-existing rows survive the migration; the
#   ingest service stamps it on every upsert going forward.
# - basis: "posted" (DK listed a team-total O/U for the team, used as-is) or
#   "derived" (only game total + spread were posted, so we compute). Nullable for
#   legacy rows; the service always stamps it now.
# - posted_line / over_odds / under_odds: DK's own team-total number and its
#   two-sided odds, kept alongside the derived expected_points so the gap between
#   DK's line and ours becomes a standing accuracy check. Blank when unposted.
# See docs/workflows/market-snapshot.md steps 2 and 4.
class AddMarketSnapshotAndBasisToProjections < ActiveRecord::Migration[8.1]
  def change
    add_reference :nfl_team_total_projections, :market_snapshot,
      null: true, foreign_key: true, index: true

    add_column :nfl_team_total_projections, :basis, :string
    add_column :nfl_team_total_projections, :posted_line, :decimal, precision: 5, scale: 2
    add_column :nfl_team_total_projections, :over_odds, :integer
    add_column :nfl_team_total_projections, :under_odds, :integer
  end
end
