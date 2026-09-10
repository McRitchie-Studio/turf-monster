# The playing profile for a Person. Carries the physical attributes, the draft
# record, and the cross-reference IDs that let every downstream importer match
# on an identifier instead of a name.
#
# Lifted from mcritchie-studio. Headshots live in ImageCache (studio-engine),
# cached to S3 at the widths in Nfl::HEADSHOT_WIDTHS.
class Athlete < ApplicationRecord
  include Sluggable

  belongs_to :person, foreign_key: :person_slug, primary_key: :slug
  belongs_to :team, foreign_key: :team_slug, primary_key: :slug, optional: true

  has_many :image_caches, as: :owner, class_name: "ImageCache", dependent: :destroy

  validates :person_slug, presence: true, uniqueness: true
  validates :sport, presence: true

  scope :football, -> { where(sport: "football") }
  scope :on_a_team, -> { where.not(team_slug: nil) }
  scope :for_team, ->(slug) { where(team_slug: slug) }
  scope :for_position, ->(pos) { where(position: pos) }

  # Ordered for a roster view: offense, then defense, then special teams, and
  # alphabetically inside each position. Position leads — ordering by name
  # first would interleave every position and defeat the grouping.
  scope :in_roster_order, -> {
    joins(:person)
      .order(Arel.sql(PositionConcern.position_order_sql))
      .order("people.last_name", "people.first_name")
  }

  def name_slug
    "#{person_slug}-athlete"
  end

  def full_name
    person&.full_name
  end

  # Cached S3 headshot at the requested width, or nil when we never cached one
  # (no espn_id, or the upload has not run yet). Callers fall back to a
  # placeholder rather than hotlinking ESPN.
  def headshot_url(width: 400)
    image_caches.detect { |c| c.purpose == "headshot" && c.variant == width.to_s }&.url
  end

  # nflverse lists every school a player attended, primary first, joined with
  # "; " — Josh Allen reads "Wyoming; Reedley". The full string is kept in the
  # column; this is what a player card shows.
  def college_display
    college_name.presence&.split(";")&.first&.strip
  end

  def height_display
    return nil if height_inches.blank? || height_inches.zero?

    %(#{height_inches / 12}'#{height_inches % 12}")
  end
end
