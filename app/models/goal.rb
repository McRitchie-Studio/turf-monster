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
  # A GOAL'S POINTS CAN CHANGE AFTER IT IS WRITTEN.
  #
  # ESPN does not report the extra point as its own play — it folds the try into
  # the touchdown that earned it and RESTATES that same play, 6 while the kick
  # is in the air and 7 once it is good. So a goal caught mid-try is amended,
  # not replaced, and with only a create and a destroy hook here that amendment
  # moved the goal row and nothing else: the game score, its slate matchups, and
  # every contest scored off them kept the old number.
  after_update :refresh_game_scores, if: :score_relevant_change?
  after_destroy :refresh_game_scores

  # Live page (Turbo Streams over ActionCable). _commit so scores recomputed by
  # refresh_game_scores (above, runs first) are committed before we broadcast.
  after_create_commit  -> { Contest::LiveBroadcast.goal_scored(self) }
  after_create_commit  -> { Nfl::LiveBroadcast.scoring_event(self) }
  after_destroy_commit -> { Contest::LiveBroadcast.score_changed(game, event: :goal_removed) }
  after_destroy_commit -> { Nfl::LiveBroadcast.score_changed(game) }

  # An amendment moves the score without being a new scoring event, so it takes
  # the score_changed road rather than the toast road: the boards redraw at the
  # corrected number and nobody is announced as scoring twice.
  after_update_commit -> { Contest::LiveBroadcast.score_changed(game, event: :goal_amended) },
                      if: :score_relevant_change?
  after_update_commit -> { Nfl::LiveBroadcast.score_changed(game) }, if: :score_relevant_change?

  # THE SCORER, resolved to a roster athlete.
  #
  # `scorer_name` is what ESPN's play text said; this turns it into the
  # `athletes.person_slug` that reaches a headshot. Returns nil freely — a
  # practice-squad call-up or a player signed after the last roster seed has no
  # athlete record, and the card names them without a photo rather than not at
  # all.
  #
  # The suffix retry is worth its two lines: ESPN writes "Harold Fannin Jr."
  # where nflverse stores "Harold Fannin", and Person.find_by_name matches on
  # slug, punctuation and alias but NOT on a suffix. Measured across 141 real
  # scorers, the retry lifts resolution from 87% to 90%.
  SUFFIX = /\s+(?:Jr\.?|Sr\.?|I{2,3}|IV|V)\z/i

  def self.resolve_scorer_slug(name)
    return nil if name.blank?

    person = find_person_by_full_name(name)
    person ||= find_person_by_full_name(name.sub(SUFFIX, ""))
    return nil unless person&.athlete_profile

    person.slug
  end

  def self.find_person_by_full_name(name)
    parts = name.to_s.strip.split(/\s+/)
    return nil if parts.size < 2

    Person.find_by_name(parts.first, parts[1..].join(" "))
  end
  private_class_method :find_person_by_full_name

  # The athlete who scored, when we hold one. Slug-keyed like every other
  # association on this page.
  def scorer_athlete
    return nil if scorer_slug.blank?

    @scorer_athlete ||= Athlete.includes(:image_caches).find_by(person_slug: scorer_slug)
  end

  # A cached headshot at the requested width, or nil. The card falls back to the
  # scorer's initials, the same fallback the roster pages use.
  def scorer_headshot_url(width: 400)
    scorer_athlete&.headshot_url(width: width)
  end

  # SHOULD THIS SCORE TAKE OVER THE FOCUS PANEL?
  #
  # Touchdowns and field goals only. The extra point and the two-point try are
  # folded into the touchdown by ESPN and arrive as an AMENDMENT to the same
  # row, so treating them as their own reveal would interrupt twice for one
  # drive; a safety rarely names a single clean scorer.
  REVEALING_TYPES = %w[touchdown field_goal].freeze

  def reveals_scorer?
    REVEALING_TYPES.include?(scoring_type.to_s) && scorer_name.present?
  end

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

  # Only the columns a score is computed from. Every other write — a play's
  # text, a late player attribution — must not drag the whole propagation chain
  # (matchups, contests, two broadcasts) behind it.
  def score_relevant_change?
    saved_change_to_points? || saved_change_to_team_slug? || saved_change_to_game_slug?
  end
end
