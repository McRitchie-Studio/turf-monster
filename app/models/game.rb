class Game < ApplicationRecord
  include Sluggable

  # ESPN's own season vocabulary, mirrored so the importer never has to
  # translate and the scoreboard can label a slot without a second lookup.
  SEASON_TYPES = { 1 => "preseason", 2 => "regular", 3 => "postseason" }.freeze

  # The slug suffix each season type contributes. Regular season contributes
  # NOTHING — its games keep the bare "<home>-vs-<away>" slug they already have
  # in production, referenced by live SlateMatchup rows. Only the season types
  # that can collide with it carry a discriminator.
  SEASON_TYPE_SLUG_PREFIX = { 1 => "pre", 3 => "post" }.freeze

  belongs_to :home_team, class_name: "Team", foreign_key: :home_team_slug, primary_key: :slug
  belongs_to :away_team, class_name: "Team", foreign_key: :away_team_slug, primary_key: :slug
  belongs_to :advancing_team, class_name: "Team", foreign_key: :advancing_team_slug, primary_key: :slug, optional: true
  belongs_to :survivor_round, optional: true
  has_many :goals, foreign_key: :game_slug, primary_key: :slug, dependent: :destroy
  has_many :nfl_team_total_projections, foreign_key: :game_slug, primary_key: :slug, dependent: :destroy

  # Games are shared across sports — the World Cup contests live in this same
  # table — so anything that renders an NFL surface has to say so. Scoping on
  # the HOME team is enough: a game is never played between leagues, and
  # checking one side keeps this a single subquery.
  scope :nfl, -> { where(home_team_slug: Team.nfl.select(:slug)) }

  scope :in_season_slot, ->(year:, season_type:, week:) {
    where(season_year: year, season_type: season_type, week: week).order(:kickoff_at)
  }

  # Recount goals and update home_score / away_score from Goal records.
  #
  # SUM, not COUNT. A count says every scoring event is worth one point, which
  # is true of a soccer goal and false of a touchdown. `goals.points` defaults
  # to 1, so every row written before that column existed sums to exactly what
  # it used to count — this change is a no-op for World Cup scores and the only
  # reason NFL scores can be represented at all.
  def update_scores_from_goals!
    self.home_score = goals.where(team_slug: home_team_slug).sum(:points)
    self.away_score = goals.where(team_slug: away_team_slug).sum(:points)
    save!
    update_slate_matchups!
  end

  # Propagate scores to all SlateMatchups referencing this game
  def update_slate_matchups!
    SlateMatchup.where(game_slug: slug).find_each do |matchup|
      team_goals = if matchup.team_slug == home_team_slug
        home_score
      elsif matchup.team_slug == away_team_slug
        away_score
      end
      matchup.update!(goals: team_goals) if team_goals
    end
    score_affected_contests!
  end

  # Find all contests that include this game's matchups and re-score entries.
  #
  # A multi-week contest is played on ONE span slate holding every week's games,
  # so this scalar slate_id lookup reaches weeks 2 and 3 without a join — that is
  # a direct benefit of converging onto the span-slate model.
  #
  # Each contest is scored independently: one entry that raises must not abort
  # the loop and leave every later contest silently unscored.
  def score_affected_contests!
    slate_ids = SlateMatchup.where(game_slug: slug).pluck(:slate_id).uniq
    return if slate_ids.empty?

    Contest.where(slate_id: slate_ids, status: [:open]).find_each do |contest|
      begin
        contest.score_entries!
      rescue StandardError => e
        Rails.logger.error("[Game#score_affected_contests!] game=#{slug} contest=#{contest.slug} #{e.class}: #{e.message}")
        ErrorLog.capture!(e)
      end
    end
  end

  # "<home>-vs-<away>", plus a season discriminator for the season types that
  # would otherwise collide with the regular season.
  #
  # This is not a theoretical guard. Two teams genuinely meet twice in one
  # calendar year — in the real 2026 schedule, LAC hosts SF in preseason week 3
  # (Aug 21) and again in regular-season week 15 (Dec 18), and SEA hosts DAL in
  # preseason week 2 and regular-season week 13. Without the suffix, importing
  # August exhibition scores would overwrite the December games.
  def name_slug
    base = "#{home_team_slug}-vs-#{away_team_slug}"
    prefix = SEASON_TYPE_SLUG_PREFIX[season_type]
    return base unless prefix

    [base, "#{prefix}#{week}"].join("-")
  end

  def season_type_name
    SEASON_TYPES[season_type]
  end

  def preseason?  = season_type == 1
  def regular_season? = season_type == 2

  # ESPN's status vocabulary, collapsed to the three states the scoreboard
  # actually renders. `status` is a free-text column with a "scheduled" default,
  # so anything unrecognised reads as scheduled rather than raising.
  def live?      = status == "in_progress"
  def completed? = status == "completed"

  def expected_total_for(team_or_slug)
    team_slug = team_or_slug.respond_to?(:slug) ? team_or_slug.slug : team_or_slug
    nfl_team_total_projections.find { |projection| projection.team_slug == team_slug }&.expected_points
  end

  def home_expected_total
    expected_total_for(home_team_slug)
  end

  def away_expected_total
    expected_total_for(away_team_slug)
  end
end
