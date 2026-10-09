# THE TWO ENTRANTS on the /turf-monster-v2 hero laptop's leaderboard: Mason
# and Turf, the only rows the laptop's board ever draws. The contest is
# fictional (LaptopFictionalShowcase), so there are no real entries to sit
# beside them and no real user can appear, whatever the database holds.
#
# DISPLAY-ONLY. Every Entry, User and Selection here is a new, unsaved
# in-memory record marked readonly!, so a save anywhere in the render path
# raises instead of writing. The avatars are not attachments either:
# LaptopLiveSnapshot swaps each row's initials disc for its IMAGE after the
# render (#showcase_avatars), keyed on the row's data-entry-slug.
class LaptopShowcaseEntrants
  # slug: the row's data-entry-slug. image: an asset under app/assets/images.
  # holds: the side of the featured game this entrant picked (Mason the home
  # Cowboys, Turf the away 49ers). hand: the entrant's other five picks, by
  # LaptopFictionalShowcase::TEAMS abbreviation.
  ENTRANTS = [
    { name: "Mason", slug: "showcase-mason", image: "showcase/mason.webp", holds: :home, hand: %w[BUF CHI KC PIT MIN] },
    { name: "Turf",  slug: "showcase-turf",  image: "showcase/turf.webp",  holds: :away, hand: %w[MIA GB DEN BAL DET] }
  ].freeze

  SLUG_PREFIX = "showcase-".freeze

  def self.image_for(slug)
    ENTRANTS.find { |e| e[:slug] == slug }&.fetch(:image)
  end

  # THE SCRIPTED BOARD. The board reacts to the simulated touchdowns
  # (LaptopScoreSimulation): every touchdown in the featured game moves its
  # holder's total, and the lead changes hands with each one. Mason leads the
  # 3-7 opening (the Cowboys' touchdown), Turf takes it with the 49ers' first
  # touchdown, Mason takes it back with the Cowboys' next, and so on to the
  # final frame.
  #
  # THE MATH IS THE BOARD'S. Every pick's points are the team's points in its
  # game times that team's Turf Score (the single-week branch of
  # Selection#computed_points, written out because these picks score in-memory
  # points): the featured teams' points come from the simulated frame, every
  # other pick's from its fictional game's fixed score (the matchup's goals).
  # Each entry's total is the sum of its picks, as Entry#score! sums them.
  #
  # The fictional scores and Turf Scores are chosen so the lead swaps on every
  # touchdown; test/services/laptop_showcase_script_test.rb holds that, frame
  # by frame, so a change to LaptopFictionalShowcase that breaks it fails there.
  class Script
    def self.build(showcase, simulation)
      return nil unless simulation

      new(showcase, simulation)
    end

    # Exact decimals, as the matchup's turf_score column is: a total summed in
    # any order is the same number.
    def self.points(goals, turf_score) = BigDecimal(goals.to_i.to_s) * BigDecimal(turf_score.to_s)

    attr_reader :simulation

    def initialize(showcase, simulation)
      @contest = showcase.contest
      @simulation = simulation
      by_team = showcase.matchups.index_by(&:team_slug)
      game = simulation.source
      @featured = {
        home: by_team.fetch(game.home_team_slug),
        away: by_team.fetch(game.away_team_slug)
      }
      @hands = ENTRANTS.to_h do |entrant|
        [entrant[:slug], entrant[:hand].map { |abbr| by_team.fetch(LaptopFictionalShowcase.team_slug(abbr)) }]
      end
    end

    # Frame index => { "showcase-mason" => total, "showcase-turf" => total }
    def totals_at(index)
      entries_at(index).to_h { |entry| [entry.slug, entry.score] }
    end

    def leader_at(index) = entries_at(index).first.slug

    # The two entrants at frame `index`, highest total first.
    def entries_at(index)
      frame = @simulation.frames.fetch(index)
      ENTRANTS.map do |entrant|
        side = entrant[:holds]
        featured = [@featured.fetch(side), frame.game.public_send(:"#{side}_score")]
        build_entry(entrant, @hands.fetch(entrant[:slug]).map { |m| [m, m.goals] } << featured)
      end.sort_by { |entry| -entry.score }
    end

    private

    def build_entry(entrant, picks)
      user = User.new(username: entrant[:name]).tap(&:readonly!)
      entry = Entry.new(slug: entrant[:slug], status: "active")
      entry.association(:contest).target = @contest
      entry.association(:user).target = user
      selections = picks.map do |matchup, scored|
        Selection.new(slate_matchup: matchup).tap do |selection|
          selection.association(:entry).target = entry
          selection.points = self.class.points(scored, matchup.turf_score)
          selection.readonly!
        end
      end
      assoc = entry.association(:selections)
      assoc.target = selections
      assoc.loaded!
      entry.score = selections.sum(&:points)
      entry.readonly!
      entry
    end
  end
end
