# A market-snapshot artifact: the durable record of one market-capture run.
#
# One row is written per `market:snapshot` run (or per season-wide
# `nfl:expected_team_totals_cache` run), and every projection the run upserts
# belongs_to it. It answers, after the fact, "what did we capture, from where,
# into which seed file, and how much of it was DK-posted vs. derived?" — the job
# the committed debug PNGs used to (badly) do.
#
# See docs/workflows/market-snapshot.md step 4.
class MarketSnapshot < ApplicationRecord
  BASES = %w[posted derived].freeze

  has_many :nfl_team_total_projections, dependent: :nullify

  validates :sport, :source, :dataset_path, :checksum, :captured_at, presence: true
  validates :year, numericality: { only_integer: true, greater_than_or_equal_to: 2026 }
  validates :week, numericality: { only_integer: true, in: 1..18 }, allow_nil: true
  validates :row_count, :posted_count, :derived_count,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :for_sport, ->(sport) { where(sport: sport) }
  scope :recent_first, -> { order(captured_at: :desc) }

  def label
    scope = week ? "#{sport} #{year} week #{week}" : "#{sport} #{year} season"
    "#{scope} — #{row_count} rows (#{posted_count} posted, #{derived_count} derived)"
  end
end
