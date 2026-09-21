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

  # THIS TABLE IS A REPLICA, NOT A MASTER.
  #
  # McRitchie Studio owns person/athlete/team; turf-monster owns events. A row
  # carrying `synced_at` came from that projection, and editing it here is a
  # silent no-op at best: the next sync overwrites it and nobody can say which
  # value was right. A replica that is only CONVENTIONALLY read-only becomes a
  # second master by accident, so the refusal is enforced rather than documented.
  #
  # The sync itself sets `syncing` to write legitimately.
  attr_accessor :syncing

  before_save :refuse_local_writes_to_synced_rows

  # The columns McRitchie Studio owns on a synced row. Anything NOT here stays
  # locally writable — this app's own importers fill draft and college data the
  # master neither holds nor sends.
  STUDIO_MASTERED = %w[
    sport position team_slug height_inches weight_lbs espn_headshot_url
    gsis_id espn_id nflverse_id pff_id otc_id pfr_id sleeper_id
  ].freeze

  validates :person_slug, presence: true, uniqueness: true
  validates :sport, presence: true

  scope :synced, -> { where.not(synced_at: nil) }
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

  private

  def refuse_local_writes_to_synced_rows
    return if syncing
    return if synced_at.blank?           # never synced — this row is ours
    return unless changed?               # a no-op save is harmless

    # THE AXIS IS "DOES THE MASTER OWN THIS COLUMN", not "is this provenance".
    #
    # The first cut refused every column except the sync's own bookkeeping,
    # which locked out this app's OWN nflverse importer — measured attempting
    # college_name, draft_pick, draft_round, draft_year and jersey_number, none
    # of which McRitchie Studio masters or sends. A synced athlete therefore
    # rendered "Drafted: Undrafted" forever, and the importer's rescue does not
    # catch ReadOnlyRecord (it rescues RecordInvalid/RecordNotUnique, siblings
    # rather than ancestors), so the write died rather than degrading.
    #
    # So: refuse a local write to a column the MASTER owns, and leave the rest
    # alone. STUDIO_MASTERED is asserted against the projection's own key set in
    # the sync's test, so the two cannot drift apart silently.
    local = changed & STUDIO_MASTERED
    return if local.empty?

    raise ActiveRecord::ReadOnlyRecord,
          "athlete #{person_slug} is synced from McRitchie Studio — change it there, not here " \
          "(attempted: #{local.join(', ')})"
  end
end
