require "time"

# Idempotent seed for the FIFA World Cup 2026 elimination-round fixture slate.
# Source: FIFA FDCP API, competition 17, season 285023.
# https://api.fifa.com/api/v3/calendar/matches?language=en&idSeason=285023&count=200
class WorldCup2026KnockoutSeed
  SOURCE_URL = "https://api.fifa.com/api/v3/calendar/matches?language=en&idSeason=285023&count=200".freeze
  DEFAULT_RANKING_ODDS = {
    "ESP" => 450,   "FRA" => 600,   "ENG" => 600,   "BRA" => 850,
    "ARG" => 850,   "POR" => 1100,  "GER" => 1400,  "NED" => 2000,
    "NOR" => 2800,  "BEL" => 3500,  "COL" => 4000,  "JPN" => 5000,
    "MAR" => 6000,  "URU" => 6500,  "USA" => 6500,  "TUR" => 6500,
    "MEX" => 7000,  "SWE" => 8000,  "ECU" => 8000,  "CRO" => 9000,
    "SUI" => 10_000, "SEN" => 10_000, "AUT" => 10_000, "CZE" => 15_000,
    "CAN" => 20_000, "PAR" => 20_000, "SCO" => 20_000, "CIV" => 25_000,
    "BIH" => 25_000, "EGY" => 30_000, "IRN" => 30_000, "ALG" => 35_000,
    "KOR" => 35_000, "GHA" => 35_000, "AUS" => 45_000, "TUN" => 50_000,
    "COD" => 70_000, "RSA" => 80_000, "KSA" => 100_000, "PAN" => 100_000,
    "NZL" => 100_000, "QAT" => 100_000, "CPV" => 100_000, "IRQ" => 100_000,
    "UZB" => 150_000, "JOR" => 150_000, "HAI" => 150_000, "CUW" => 150_000
  }.freeze

  SLATES = [
    { stage: "Round of 32", name: "World Cup 2026 Round of 32" },
    { stage: "Round of 16", name: "World Cup 2026 Round of 16" },
    { stage: "Quarter-final", name: "World Cup 2026 Quarter-finals" },
    { stage: "Semi-final", name: "World Cup 2026 Semi-finals" },
    { stage: "Play-off for third place", name: "World Cup 2026 Third Place" },
    { stage: "Final", name: "World Cup 2026 Final" }
  ].freeze

  PLACEHOLDER_LABELS = {
    "W74" => "Winner Match 74",
    "W75" => "Winner Match 75",
    "W76" => "Winner Match 76",
    "W77" => "Winner Match 77",
    "W78" => "Winner Match 78",
    "W79" => "Winner Match 79",
    "W80" => "Winner Match 80",
    "W81" => "Winner Match 81",
    "W82" => "Winner Match 82",
    "W83" => "Winner Match 83",
    "W84" => "Winner Match 84",
    "W85" => "Winner Match 85",
    "W86" => "Winner Match 86",
    "W87" => "Winner Match 87",
    "W88" => "Winner Match 88",
    "W89" => "Winner Match 89",
    "W90" => "Winner Match 90",
    "W91" => "Winner Match 91",
    "W92" => "Winner Match 92",
    "W93" => "Winner Match 93",
    "W94" => "Winner Match 94",
    "W95" => "Winner Match 95",
    "W96" => "Winner Match 96",
    "W97" => "Winner Match 97",
    "W98" => "Winner Match 98",
    "W99" => "Winner Match 99",
    "W100" => "Winner Match 100",
    "W101" => "Winner Match 101",
    "W102" => "Winner Match 102",
    "RU101" => "Runner-up Match 101",
    "RU102" => "Runner-up Match 102"
  }.freeze

  OBSOLETE_PLACEHOLDER_CODES = %w[
    1K 1L 2J 2K 2L
    3AEHIJ 3BEFIJ 3CEFHI 3CDFGH 3DEIJL 3EFGIJ 3EHIJK
    W73
  ].freeze

  FIXTURES = [
    { match: 73, stage: "Round of 32", kickoff_at: "2026-06-28T19:00:00Z", venue: "Los Angeles Stadium, Los Angeles", home: "RSA", away: "CAN" },
    { match: 74, stage: "Round of 32", kickoff_at: "2026-06-29T20:30:00Z", venue: "Boston Stadium, Boston", home: "GER", away: "PAR" },
    { match: 75, stage: "Round of 32", kickoff_at: "2026-06-30T01:00:00Z", venue: "Monterrey Stadium, Monterrey", home: "NED", away: "MAR" },
    { match: 76, stage: "Round of 32", kickoff_at: "2026-06-29T17:00:00Z", venue: "Houston Stadium, Houston", home: "BRA", away: "JPN" },
    { match: 77, stage: "Round of 32", kickoff_at: "2026-06-30T21:00:00Z", venue: "New York/New Jersey Stadium, New Jersey", home: "FRA", away: "SWE" },
    { match: 78, stage: "Round of 32", kickoff_at: "2026-06-30T17:00:00Z", venue: "Dallas Stadium, Dallas", home: "CIV", away: "NOR" },
    { match: 79, stage: "Round of 32", kickoff_at: "2026-07-01T01:00:00Z", venue: "Mexico City Stadium, Mexico City", home: "MEX", away: "ECU" },
    { match: 80, stage: "Round of 32", kickoff_at: "2026-07-01T16:00:00Z", venue: "Atlanta Stadium, Atlanta", home: "ENG", away: "COD" },
    { match: 81, stage: "Round of 32", kickoff_at: "2026-07-02T00:00:00Z", venue: "San Francisco Bay Area Stadium, San Francisco Bay Area", home: "USA", away: "BIH" },
    { match: 82, stage: "Round of 32", kickoff_at: "2026-07-01T20:00:00Z", venue: "Seattle Stadium, Seattle", home: "BEL", away: "SEN" },
    { match: 83, stage: "Round of 32", kickoff_at: "2026-07-02T23:00:00Z", venue: "Toronto Stadium, Toronto", home: "POR", away: "CRO" },
    { match: 84, stage: "Round of 32", kickoff_at: "2026-07-02T19:00:00Z", venue: "Los Angeles Stadium, Los Angeles", home: "ESP", away: "AUT" },
    { match: 85, stage: "Round of 32", kickoff_at: "2026-07-03T03:00:00Z", venue: "BC Place Vancouver, Vancouver", home: "SUI", away: "ALG" },
    { match: 86, stage: "Round of 32", kickoff_at: "2026-07-03T22:00:00Z", venue: "Miami Stadium, Miami", home: "ARG", away: "CPV" },
    { match: 87, stage: "Round of 32", kickoff_at: "2026-07-04T01:30:00Z", venue: "Kansas City Stadium, Kansas City", home: "COL", away: "GHA" },
    { match: 88, stage: "Round of 32", kickoff_at: "2026-07-03T18:00:00Z", venue: "Dallas Stadium, Dallas", home: "AUS", away: "EGY" },
    { match: 89, stage: "Round of 16", kickoff_at: "2026-07-04T21:00:00Z", venue: "Philadelphia Stadium, Philadelphia", home: "W74", away: "W77" },
    { match: 90, stage: "Round of 16", kickoff_at: "2026-07-04T17:00:00Z", venue: "Houston Stadium, Houston", home: "CAN", away: "W75" },
    { match: 91, stage: "Round of 16", kickoff_at: "2026-07-05T20:00:00Z", venue: "New York/New Jersey Stadium, New Jersey", home: "W76", away: "W78" },
    { match: 92, stage: "Round of 16", kickoff_at: "2026-07-06T00:00:00Z", venue: "Mexico City Stadium, Mexico City", home: "W79", away: "W80" },
    { match: 93, stage: "Round of 16", kickoff_at: "2026-07-06T19:00:00Z", venue: "Dallas Stadium, Dallas", home: "W83", away: "W84" },
    { match: 94, stage: "Round of 16", kickoff_at: "2026-07-07T00:00:00Z", venue: "Seattle Stadium, Seattle", home: "W81", away: "W82" },
    { match: 95, stage: "Round of 16", kickoff_at: "2026-07-07T16:00:00Z", venue: "Atlanta Stadium, Atlanta", home: "W86", away: "W88" },
    { match: 96, stage: "Round of 16", kickoff_at: "2026-07-07T20:00:00Z", venue: "BC Place Vancouver, Vancouver", home: "W85", away: "W87" },
    { match: 97, stage: "Quarter-final", kickoff_at: "2026-07-09T20:00:00Z", venue: "Boston Stadium, Boston", home: "W89", away: "W90" },
    { match: 98, stage: "Quarter-final", kickoff_at: "2026-07-10T19:00:00Z", venue: "Los Angeles Stadium, Los Angeles", home: "W93", away: "W94" },
    { match: 99, stage: "Quarter-final", kickoff_at: "2026-07-11T21:00:00Z", venue: "Miami Stadium, Miami", home: "W91", away: "W92" },
    { match: 100, stage: "Quarter-final", kickoff_at: "2026-07-12T01:00:00Z", venue: "Kansas City Stadium, Kansas City", home: "W95", away: "W96" },
    { match: 101, stage: "Semi-final", kickoff_at: "2026-07-14T19:00:00Z", venue: "Dallas Stadium, Dallas", home: "W97", away: "W98" },
    { match: 102, stage: "Semi-final", kickoff_at: "2026-07-15T19:00:00Z", venue: "Atlanta Stadium, Atlanta", home: "W99", away: "W100" },
    { match: 103, stage: "Play-off for third place", kickoff_at: "2026-07-18T21:00:00Z", venue: "Miami Stadium, Miami", home: "RU101", away: "RU102" },
    { match: 104, stage: "Final", kickoff_at: "2026-07-19T19:00:00Z", venue: "New York/New Jersey Stadium, New Jersey", home: "W101", away: "W102" }
  ].freeze

  def self.call(...)
    new(...).call
  end

  def self.required_real_team_codes
    fixture_team_codes - placeholder_codes
  end

  def self.placeholder_codes
    PLACEHOLDER_LABELS.keys
  end

  def self.fixture_team_codes
    FIXTURES.flat_map { |fixture| [fixture[:home], fixture[:away]] }.uniq
  end

  def self.call_from_database!(ranking_odds: DEFAULT_RANKING_ODDS)
    teams_by_code = Team.where(short_name: required_real_team_codes).index_by(&:short_name)
    missing_codes = required_real_team_codes - teams_by_code.keys

    if missing_codes.any?
      raise KeyError, "Missing World Cup teams for knockout seed codes: #{missing_codes.to_sentence}"
    end

    call(teams_by_code: teams_by_code, ranking_odds: ranking_odds)
  end

  def initialize(teams_by_code:, ranking_odds: DEFAULT_RANKING_ODDS)
    @teams_by_code = teams_by_code.stringify_keys
    @ranking_odds = ranking_odds.stringify_keys
  end

  def call
    seed_placeholder_teams!
    games_by_fixture = seed_games!
    seed_slates!(games_by_fixture)
    remove_obsolete_placeholder_games!
    remove_obsolete_placeholder_teams!
  end

  private

  attr_reader :teams_by_code, :ranking_odds

  def seed_placeholder_teams!
    self.class.placeholder_codes.each do |code|
      name = PLACEHOLDER_LABELS.fetch(code)
      team = Team.find_or_initialize_by(slug: name.parameterize)
      team.assign_attributes(
        name: name,
        short_name: code,
        location: "World Cup bracket",
        emoji: "🏆",
        color_dark: "#111827",
        color_light: "#FACC15",
        sport: "soccer",
        league: "fifa",
        division: "Knockout Slot",
        rivals: []
      )
      team.save!
      teams_by_code[code] = team
    end
  end

  def seed_games!
    FIXTURES.index_with do |fixture|
      home_team = team_for!(fixture[:home])
      away_team = team_for!(fixture[:away])

      Game.find_or_initialize_by(home_team_slug: home_team.slug, away_team_slug: away_team.slug).tap do |game|
        game.status = "scheduled" if game.new_record?
        game.kickoff_at = Time.iso8601(fixture[:kickoff_at])
        game.venue = fixture[:venue]
        game.save!
      end
    end
  end

  def seed_slates!(games_by_fixture)
    SLATES.each do |slate_spec|
      fixtures = FIXTURES.select { |fixture| fixture[:stage] == slate_spec[:stage] }
      slate = Slate.find_or_initialize_by(name: slate_spec[:name])
      slate.starts_at = fixtures.map { |fixture| Time.iso8601(fixture[:kickoff_at]) }.min
      slate.save!

      fixtures.each do |fixture|
        game = games_by_fixture.fetch(fixture)
        seed_matchup!(slate: slate, team_code: fixture[:home], opponent_code: fixture[:away], game: game)
        seed_matchup!(slate: slate, team_code: fixture[:away], opponent_code: fixture[:home], game: game)
      end

      remove_stale_matchups!(slate, fixtures)
      rank_matchups!(slate)
    end
  end

  def seed_matchup!(slate:, team_code:, opponent_code:, game:)
    team = team_for!(team_code)
    opponent = team_for!(opponent_code)
    matchup = SlateMatchup.find_or_initialize_by(slate: slate, team_slug: team.slug)
    matchup.opponent_team_slug = opponent.slug
    matchup.game_slug = game.slug
    matchup.save!
  end

  def rank_matchups!(slate)
    sorted = slate.slate_matchups.includes(:team).sort_by do |matchup|
      [ranking_odds[matchup.team.short_name] || 999_999, matchup.team.name]
    end
    sorted.each_with_index do |matchup, index|
      matchup.update!(rank: index + 1, turf_score: SlateMatchup.turf_score_for(index + 1, sorted.size))
    end
  end

  def remove_stale_matchups!(slate, fixtures)
    expected_team_slugs = fixtures.flat_map do |fixture|
      [team_for!(fixture[:home]).slug, team_for!(fixture[:away]).slug]
    end
    stale_matchups = slate.slate_matchups.where.not(team_slug: expected_team_slugs)
    protected_matchups = stale_matchups.select { |matchup| matchup.selections.exists? }

    if protected_matchups.any?
      names = protected_matchups.map { |matchup| matchup.team.name }.to_sentence
      raise "Cannot remove stale World Cup knockout matchup selections for #{names}"
    end

    stale_matchups.destroy_all
  end

  def remove_obsolete_placeholder_games!
    obsolete_slugs = obsolete_placeholder_slugs
    return if obsolete_slugs.empty?

    stale_games = Game.where(home_team_slug: obsolete_slugs).or(Game.where(away_team_slug: obsolete_slugs))
    protected_games = stale_games.select do |game|
      game.goals.exists? || SlateMatchup.where(game_slug: game.slug).exists?
    end

    if protected_games.any?
      names = protected_games.map(&:slug).to_sentence
      raise "Cannot remove stale World Cup knockout games with activity: #{names}"
    end

    stale_games.destroy_all
  end

  def remove_obsolete_placeholder_teams!
    Team.where(short_name: OBSOLETE_PLACEHOLDER_CODES).find_each do |team|
      next if team.home_games.exists? || team.away_games.exists?
      next if SlateMatchup.where(team_slug: team.slug).or(SlateMatchup.where(opponent_team_slug: team.slug)).exists?

      team.destroy!
    end
  end

  def obsolete_placeholder_slugs
    Team.where(short_name: OBSOLETE_PLACEHOLDER_CODES).pluck(:slug)
  end

  def team_for!(code)
    teams_by_code.fetch(code) do
      raise KeyError, "Missing World Cup team for knockout seed code #{code.inspect}"
    end
  end
end
