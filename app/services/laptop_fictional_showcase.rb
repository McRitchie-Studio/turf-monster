# THE FICTIONAL CONTEST the /turf-monster-v2 hero laptop shows: a made-up
# contest on a made-up slate, built entirely from unsaved, readonly, in-memory
# records. It replaced the laptop's real-contest showcase (NextContest
# .live_showcase), which put a real contest, its real games and its real
# players' usernames on the marketing page.
#
# EVERGREEN. Nothing here reads the clock or the database, so the laptop looks
# the same tomorrow as it does in two months, whatever real contests exist:
#
#   - the teams are hard-coded (TEAMS: names, emoji, and their colors from
#     Nfl::TeamPalette, a constant), never Team rows;
#   - every kickoff is a fixed instant on REFERENCE_SUNDAY, and the laptop only
#     ever prints a kickoff as a weekday and a time ("Sun 2:25 PM"), never a
#     calendar date;
#   - live games carry a fixed clock ("Q2 9:48" style), finished ones "Final";
#   - the contest has no season year in its name, and its lock is a fixed
#     instant long past, so Contest#live? is true on any date after it.
#
# test/services/laptop_fictional_showcase_test.rb builds it with SQL
# instrumentation on (zero queries) and renders it on two dates months apart
# (byte-identical HTML).
#
# THE SLATE. Six games, one per pair of teams: two finals, two being played
# (one of them the featured game) and two still to kick off. THE FEATURED GAME
# is San Francisco at Dallas: the 49ers are the away side, so they are the TOP
# row of the tile and the left of their strip chip; the Cowboys are home, the
# BOTTOM row. LaptopScoreSimulation plays it from 3-7.
#
# THE CONTEST is "Turf Monster Showcase" on the slate "NFL Sunday", with two
# entrants, Mason and Turf (LaptopShowcaseEntrants::Script): Mason holds the
# Cowboys, Turf the 49ers, so every simulated touchdown swaps the lead.
module LaptopFictionalShowcase
  CONTEST_NAME = "Turf Monster Showcase".freeze
  CONTEST_SLUG = "turf-monster-showcase".freeze
  SLATE_NAME = "NFL Sunday".freeze
  # A negative id can never collide with a row, and the DOM ids the live
  # partials build from it (contest_-1_focus) stay unique on the page.
  CONTEST_ID = -1

  # A fixed Sunday that only anchors the kickoffs. The laptop prints none of it
  # but the weekday and the time (LaptopLiveSnapshot::KICKOFF_FORMAT).
  REFERENCE_SUNDAY = Time.utc(2025, 1, 5).freeze
  # The contest locked at the first kickoff of that Sunday: long past on any
  # date the page will be served, so the contest reads as live.
  LOCKS_AT = (REFERENCE_SUNDAY + 18.hours).freeze

  FOCUS_SLUG = "showcase-sf-at-dal".freeze

  # The attributes the live partials draw: name, short name, location, emoji,
  # and the four-color palette (Nfl::TeamPalette, the seed's own source).
  TEAMS = {
    "SF" => { slug: "san-francisco-49ers", name: "San Francisco 49ers", location: "San Francisco", emoji: "⛏️" },
    "DAL" => { slug: "dallas-cowboys", name: "Dallas Cowboys", location: "Dallas", emoji: "⭐" },
    "BUF" => { slug: "buffalo-bills", name: "Buffalo Bills", location: "Buffalo", emoji: "🦬" },
    "MIA" => { slug: "miami-dolphins", name: "Miami Dolphins", location: "Miami", emoji: "🐬" },
    "GB" => { slug: "green-bay-packers", name: "Green Bay Packers", location: "Green Bay", emoji: "🧀" },
    "CHI" => { slug: "chicago-bears", name: "Chicago Bears", location: "Chicago", emoji: "🐻" },
    "KC" => { slug: "kansas-city-chiefs", name: "Kansas City Chiefs", location: "Kansas City", emoji: "🏹" },
    "DEN" => { slug: "denver-broncos", name: "Denver Broncos", location: "Denver", emoji: "🐎" },
    "BAL" => { slug: "baltimore-ravens", name: "Baltimore Ravens", location: "Baltimore", emoji: "🐦‍⬛" },
    "PIT" => { slug: "pittsburgh-steelers", name: "Pittsburgh Steelers", location: "Pittsburgh", emoji: "⚙️" },
    "DET" => { slug: "detroit-lions", name: "Detroit Lions", location: "Detroit", emoji: "🦁" },
    "MIN" => { slug: "minnesota-vikings", name: "Minnesota Vikings", location: "Minnesota", emoji: "⚔️" }
  }.freeze

  # Each pick's multiplier: the underdog carries the bigger one.
  TURF_SCORES = {
    "SF" => "1.3", "DAL" => "1.6", "BUF" => "1.2", "MIA" => "1.9", "GB" => "1.3", "CHI" => "1.8",
    "KC" => "1.1", "DEN" => "2.0", "BAL" => "1.4", "PIT" => "1.7", "DET" => "1.25", "MIN" => "1.85"
  }.freeze

  # The slate, in the strip's order (being played, then to come, then finals).
  # kickoff: minutes after REFERENCE_SUNDAY's 11:00 AM Mountain early window;
  # the two to come print as "Sun 6:20 PM" and "Mon 6:15 PM". period/clock: the
  # fixed game clock of a game being played. The featured game's clock and
  # score are LaptopScoreSimulation's, frame by frame.
  GAMES = [
    { away: "SF", home: "DAL", phase: :active, away_score: 3, home_score: 7, period: 1, clock: "4:12", kickoff: 205 },
    { away: "KC", home: "DEN", phase: :active, away_score: 14, home_score: 7, period: 2, clock: "6:15", kickoff: 205 },
    { away: "BAL", home: "PIT", phase: :upcoming, kickoff: 440 },
    { away: "DET", home: "MIN", phase: :upcoming, kickoff: 1875 },
    { away: "BUF", home: "MIA", phase: :completed, away_score: 27, home_score: 20, kickoff: 0 },
    { away: "GB", home: "CHI", phase: :completed, away_score: 24, home_score: 17, kickoff: 0 }
  ].freeze

  # Everything pages/_laptop_live draws: the contest, its games in the live
  # page's three phases, the one it opens on, the matchups and entries the
  # leaderboard reads, and the chat's lines (none: the chat shows its empty
  # state).
  Showcase = Data.define(:contest, :games, :focus_slug, :matchups, :entries, :messages)

  def self.build
    Builder.new.showcase
  end

  # A showcase game has no play-by-play. contests/_live_plays asks a game for
  # game.plays.newest_first.limit(..), a fresh query that no loaded association
  # can answer, so a showcase game (and every simulated copy of it,
  # LaptopScoreSimulation) answers with an empty relation that never reaches
  # the database.
  module NoPlays
    def plays = GamePlay.none
  end

  def self.team_slug(abbr) = TEAMS.fetch(abbr)[:slug]

  class Builder
    def showcase
      Showcase.new(contest: contest, games: games_by_phase, focus_slug: FOCUS_SLUG,
                   matchups: matchups, entries: [], messages: [])
    end

    private

    def teams
      @teams ||= TEAMS.to_h do |abbr, attrs|
        palette = Nfl::TeamPalette::PALETTE.fetch(abbr)
        team = Team.new(slug: attrs[:slug], name: attrs[:name], short_name: abbr, location: attrs[:location],
                        emoji: attrs[:emoji], league: "nfl", sport: "football",
                        color_dark: palette[:dark], color_light: palette[:light],
                        color_dark_alt: palette[:dark_alt], color_light_alt: palette[:light_alt],
                        color_alt: palette[:alt], color_grey: palette[:grey],
                        color_disposition: palette[:disposition])
        [abbr, team.tap(&:readonly!)]
      end
    end

    def games
      @games ||= GAMES.map { |spec| [spec, game(spec)] }
    end

    def game(spec)
      away = teams.fetch(spec[:away])
      home = teams.fetch(spec[:home])
      status = { active: "in_progress", upcoming: "scheduled", completed: "completed" }.fetch(spec[:phase])
      detail = case spec[:phase]
      when :active then "#{spec[:clock]} - #{spec[:period].ordinalize}"
      when :completed then "Final"
      end
      slug = spec[:away] == "SF" ? FOCUS_SLUG : "showcase-#{spec[:away].downcase}-at-#{spec[:home].downcase}"
      game = Game.new(slug: slug, away_team_slug: away.slug, home_team_slug: home.slug, status: status,
                      away_score: spec[:away_score], home_score: spec[:home_score],
                      period: spec[:period], clock: spec[:clock], status_detail: detail,
                      kickoff_at: REFERENCE_SUNDAY + 18.hours + spec[:kickoff].minutes)
      game.association(:away_team).target = away
      game.association(:home_team).target = home
      empty!(game, :goals)
      game.extend(NoPlays)
      empty!(game, :nfl_team_total_projections)
      game.readonly!
      game
    end

    def games_by_phase
      { active: [], upcoming: [], completed: [] }.tap do |phases|
        games.each { |spec, game| phases[spec[:phase]] << game }
      end
    end

    def slate
      @slate ||= Slate.new(name: SLATE_NAME, sport: "nfl").tap(&:readonly!)
    end

    def contest
      @contest ||= Contest.new(id: CONTEST_ID, name: CONTEST_NAME, slug: CONTEST_SLUG, status: "open",
                               contest_type: "tiny", game_type: "turf_totals", entry_fee_cents: 19_00,
                               max_entries: 2, starts_at: LOCKS_AT, onchain_cancelled: false).tap do |contest|
        contest.association(:slate).target = slate
        contest.readonly!
      end
    end

    def matchups
      @matchups ||= games.flat_map do |_spec, game|
        [[game.away_team, game.home_team, game.away_score], [game.home_team, game.away_team, game.home_score]]
          .map { |team, opponent, goals| matchup(game, team, opponent, goals) }
      end
    end

    def matchup(game, team, opponent, goals)
      SlateMatchup.new(slug: "showcase-#{team.short_name.downcase}", team_slug: team.slug,
                       opponent_team_slug: opponent.slug, game_slug: game.slug, goals: goals,
                       turf_score: BigDecimal(TURF_SCORES.fetch(team.short_name))).tap do |m|
        m.association(:slate).target = slate
        m.association(:team).target = team
        m.association(:opponent_team).target = opponent
        m.association(:game).target = game
        m.readonly!
      end
    end

    def empty!(record, name)
      assoc = record.association(name)
      assoc.target = []
      assoc.loaded!
    end
  end
end
