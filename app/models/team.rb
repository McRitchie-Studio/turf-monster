class Team < ApplicationRecord
  include Sluggable

  belongs_to :home_arena, class_name: "Arena", foreign_key: :home_arena_slug, primary_key: :slug, optional: true

  has_many :players, foreign_key: :team_slug, primary_key: :slug
  # NFL player database (seeded from nflverse). Separate from :players above,
  # which carries soccer goal-scorer attribution.
  has_many :athletes, foreign_key: :team_slug, primary_key: :slug
  has_many :home_games, class_name: "Game", foreign_key: :home_team_slug, primary_key: :slug
  has_many :away_games, class_name: "Game", foreign_key: :away_team_slug, primary_key: :slug
  has_many :nfl_team_total_projections, foreign_key: :team_slug, primary_key: :slug

  validates :name, presence: true

  # Which brand color is the card FIELD. dark → bg=color_dark, mascot=color_light;
  # light → the field is the lighter color (gold Saints, red Bucs), so bg and
  # mascot swap. Gives disposition_dark? / disposition_light?.
  enum :color_disposition, { dark: "dark", light: "light" }, prefix: :disposition

  before_validation :set_default_mascot, if: -> { self[:mascot].blank? && name.present? }

  scope :nfl, -> { where(league: "nfl") }
  scope :fifa, -> { where(league: "fifa") }
  scope :football, -> { where(sport: "football") }
  scope :soccer, -> { where(sport: "soccer") }

  def mascot
    self[:mascot].presence || derived_mascot
  end

  def name_slug
    name.parameterize
  end

  # Alt neutrals fall back to their family's primary color when the team curates
  # none — so callers can always ask for a dark-family / light-family alt.
  def dark_alt
    color_dark_alt.presence || color_dark
  end

  def light_alt
    color_light_alt.presence || color_light
  end

  # The card FIELD (background) and the mascot text sitting on it. Disposition
  # decides which brand color is which — see TeamColorsHelper#team_card_palette.
  def card_background
    disposition_light? ? color_light : color_dark
  end

  def card_mascot
    disposition_light? ? color_dark : color_light
  end

  private

  def set_default_mascot
    self[:mascot] = derived_mascot
  end

  def derived_mascot
    return name if location.blank?

    name.sub(/\A#{Regexp.escape(location)}\s*/, "").strip.presence || name
  end
end
