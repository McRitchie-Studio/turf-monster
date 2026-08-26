class Goal < ApplicationRecord
  include Sluggable

  # What a scoring event is WORTH, by kind. The table was built for soccer,
  # where every row is one goal is one point; American football needs a row to
  # carry its own value, and `points` (default 1) is how it does that.
  #
  # `pat` is the point-after kick and `two_point` the conversion — they arrive
  # from the feed folded into the touchdown that set them up, but the dev
  # toolbar and the admin console can record them on their own, so both need a
  # value here.
  #
  # `goal` keeps the soccer meaning and the soccer value. It is the default for
  # a row that names no type, which is every row written before this column
  # existed.
  SCORING_TYPE_POINTS = {
    "touchdown"  => 6,
    "field_goal" => 3,
    "two_point"  => 2,
    "safety"     => 2,
    "pat"        => 1,
    "goal"       => 1
  }.freeze

  SCORING_TYPES = SCORING_TYPE_POINTS.keys.freeze

  # Human labels for the live toast. Deliberately NOT derived by titleizing the
  # key: "Pat" is a name and "Two Point" is not what anyone shouts.
  SCORING_TYPE_LABELS = {
    "touchdown"  => "Touchdown",
    "field_goal" => "Field Goal",
    "two_point"  => "2-Point Conversion",
    "safety"     => "Safety",
    "pat"        => "Extra Point",
    "goal"       => "Goal"
  }.freeze

  belongs_to :game, foreign_key: :game_slug, primary_key: :slug
  belongs_to :team, foreign_key: :team_slug, primary_key: :slug
  belongs_to :player, foreign_key: :player_slug, primary_key: :slug, optional: true

  validates :points, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :scoring_type, inclusion: { in: SCORING_TYPES }, allow_nil: true

  after_create :update_slug_with_id
  after_create :refresh_game_scores
  after_destroy :refresh_game_scores

  # Live page (Turbo Streams over ActionCable). _commit so scores recomputed by
  # refresh_game_scores (above, runs first) are committed before we broadcast.
  after_create_commit  -> { Contest::LiveBroadcast.goal_scored(self) }
  after_create_commit  -> { Nfl::LiveBroadcast.scoring_event(self) }
  after_destroy_commit -> { Contest::LiveBroadcast.score_changed(game, event: :goal_removed) }
  after_destroy_commit -> { Nfl::LiveBroadcast.score_changed(game) }

  # The points a scoring type is worth. Falls back to 1 — the soccer value and
  # the column default — so an unrecognised type can never silently score zero.
  def self.points_for(scoring_type)
    SCORING_TYPE_POINTS.fetch(scoring_type.to_s, 1)
  end

  def name_slug
    "goal-#{id}"
  end

  def to_param
    slug
  end

  # What the live toast announces. Soccer rows and typeless rows keep saying
  # "Goal", which is what they have always said.
  def scoring_label
    SCORING_TYPE_LABELS.fetch(scoring_type.to_s, "Goal")
  end

  private

  def update_slug_with_id
    update_column(:slug, name_slug)
  end

  def refresh_game_scores
    game.update_scores_from_goals!
  end
end
