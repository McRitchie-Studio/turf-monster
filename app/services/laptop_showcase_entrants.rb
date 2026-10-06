# SHOWCASE ENTRANTS for the /turf-monster-v2 hero laptop (Alex, 2026-10-06).
#
# When the contest the laptop shows has fewer than MIN_REAL real entries, its
# leaderboard is mostly "Open" seats, which sells nothing. So the laptop's
# board, and ONLY the laptop's board, gains three entrants: Mason, turf and
# mack, each with an avatar image, drawn by the REAL leaderboard partial
# (contests/_turf_totals_leaderboard) exactly as a real entry would be.
#
# DISPLAY-ONLY. Every Entry, User and Selection here is a new, unsaved
# in-memory record marked readonly!, so a save anywhere in the render path
# raises instead of writing. No row, user or attachment is created in any
# database, and the real contest is never touched: the showcase is a copy of
# NextContest::LiveShowcase with a longer entries list, nothing more. The
# avatars are not attachments either; LaptopLiveSnapshot swaps each showcase
# row's initials disc for its IMAGE after the render.
#
# REAL PICKS, REAL MATH. Each entrant picks contest.picks_required teams from
# the contest's own matchups, and is scored with Selection#computed_points,
# the formula #compute_points! writes for a real pick, summed as Entry#score!
# sums. The matchups are ranked by those points and dealt out in turn (Mason
# first, then turf, then mack), so Mason's board is never behind turf's and
# turf's never behind mack's; with no goals scored anywhere all three tie at
# 0, and the leaderboard's own rule then withholds the crown, as it would for
# real entries.
#
# ORDER. Real entries keep their own rows, ranks and prizes: the showcase
# entrants are appended BELOW them, never ranked among them, so a made-up name
# never outranks a real player (and a settled contest, whose rows read their
# stored rank, never shows two 1st places). With 3 or more real entries
# nothing changes.
class LaptopShowcaseEntrants
  MIN_REAL = 3

  # slug: the row's data-entry-slug, which is how LaptopLiveSnapshot finds the
  # row to give it its image. image: an asset under app/assets/images.
  ENTRANTS = [
    { name: "Mason", slug: "showcase-mason", image: "showcase/mason.webp" },
    { name: "turf",  slug: "showcase-turf",  image: "showcase/turf.webp" },
    { name: "mack",  slug: "showcase-mack",  image: "showcase/mack.webp" }
  ].freeze

  SLUG_PREFIX = "showcase-".freeze

  def self.fill(showcase)
    return showcase if showcase.entries.size >= MIN_REAL

    showcase_entries = new(showcase).entries
    return showcase if showcase_entries.empty?

    showcase.with(entries: showcase.entries + showcase_entries)
  end

  def self.image_for(slug)
    ENTRANTS.find { |e| e[:slug] == slug }&.fetch(:image)
  end

  def initialize(showcase)
    @contest = showcase.contest
    @matchups = showcase.matchups
  end

  def entries
    picks = deal
    return [] if picks.empty?

    ENTRANTS.each_with_index.map { |entrant, i| entry_for(entrant, picks[i]) }
  end

  private

  # One matchup per team, best first by the points a pick on it scores now,
  # dealt round-robin so each entrant gets picks_required distinct teams.
  def deal
    per_team = @matchups.group_by(&:team_slug).map { |_, list| list.first }
    return [] if per_team.empty?

    probe = probe_entry
    ranked = per_team.sort_by do |m|
      points = Selection.new(slate_matchup: m).tap { |s| s.association(:entry).target = probe }.computed_points
      [-points.to_f, -m.turf_score.to_f, m.team_slug.to_s]
    end
    count = @contest.picks_required.to_i.clamp(1, 6)
    hands = Array.new(ENTRANTS.size) { [] }
    ranked.cycle.each_with_index do |matchup, i|
      break if hands.all? { |hand| hand.size >= count } || i >= ranked.size * ENTRANTS.size * 2

      hand = hands[i % ENTRANTS.size]
      hand << matchup if hand.size < count && hand.none? { |m| m.team_slug == matchup.team_slug }
    end
    hands
  end

  def probe_entry
    Entry.new.tap { |e| e.association(:contest).target = @contest }
  end

  def entry_for(entrant, matchups)
    user = User.new(username: entrant[:name]).tap(&:readonly!)
    entry = Entry.new(slug: entrant[:slug], status: "active")
    entry.association(:contest).target = @contest
    entry.association(:user).target = user
    selections = matchups.map do |matchup|
      Selection.new(slate_matchup: matchup).tap do |selection|
        selection.association(:entry).target = entry
        selection.points = selection.computed_points
        selection.readonly!
      end
    end
    selections_assoc = entry.association(:selections)
    selections_assoc.target = selections
    selections_assoc.loaded!
    entry.score = selections.sum { |s| s.points || 0 }
    entry.readonly!
    entry
  end
  # THE SCRIPTED BOARD (Alex, 2026-10-06: "for our purposes we can script the
  # plays"). When the laptop's contest has NO real entries and its featured
  # game is simulated (LaptopScoreSimulation), the showcase board reacts to the
  # simulated touchdowns: Mason holds the featured game's HOME team, turf its
  # AWAY team, and mack neither, so every touchdown trades first place between
  # Mason and turf (away scores first: turf goes top, then Mason takes it
  # back). A contest with any real entry never gets this: its board is never
  # moved by the simulation.
  #
  # THE MATH IS THE BOARD'S. Every pick's points are the team's points in its
  # game times that team's Turf Score (the single-week branch of
  # Selection#computed_points, written out because these picks score scripted,
  # in-memory points rather than the matchup rows' own): the featured teams'
  # points come from the simulated frame, the other picks' are scripted. Each
  # entry's total is the sum of its picks, as Entry#score! sums them.
  #
  # THE SCRIPT. Mason's and turf's other five picks carry scripted points, and
  # one of them (the fourth) is tuned so the gap between the two sits inside the
  # window where every touchdown flips the lead: above every
  # away-minus-home margin of a Mason frame, below every one of a turf frame.
  # mack's six are held under both all game. No window exists when the two
  # featured teams' Turf Scores are too far apart (roughly 1.5x); .build then
  # answers nil and the board stays as the plain showcase draws it.
  class Script
    MASON_BASE = [17, 14, 21, 10, 13].freeze
    TURF_BASE  = [20, 16, 13, 17, 9].freeze
    MACK_BASE  = [10, 7, 13, 6, 9, 3].freeze
    PICKS = 6

    def self.build(showcase, simulation)
      return nil unless simulation && showcase.entries.empty?

      new(showcase, simulation).tap { |script| return nil unless script.valid? }
    end

    # Exact decimals, as the matchup's turf_score column is: a total summed in
    # any order is the same number.
    def self.points(goals, turf_score) = BigDecimal(goals.to_s) * BigDecimal(turf_score.to_s)

    attr_reader :simulation

    def initialize(showcase, simulation)
      @contest = showcase.contest
      @simulation = simulation
      by_team = showcase.matchups.select { |m| m.turf_score.present? }.group_by(&:team_slug).transform_values(&:first)
      game = simulation.source
      @home = by_team[game.home_team_slug]
      @away = by_team[game.away_team_slug]
      others = by_team.values.reject { |m| [game.home_team_slug, game.away_team_slug].include?(m.team_slug) }
                      .sort_by { |m| [-m.turf_score.to_f, m.team_slug.to_s] }
      @hands = [[], [], []]
      others.each_with_index { |m, i| @hands[i % 3] << m }
      @goals = { mason: MASON_BASE.dup, turf: TURF_BASE.dup, mack: MACK_BASE.dup }
      @valid = @home && @away && @hands[0].size >= PICKS - 1 && @hands[1].size >= PICKS - 1 && @hands[2].size >= PICKS &&
               balance! && hold_mack_under!
    end

    def valid? = @valid

    # Frame index => { "showcase-mason" => total, ... }
    def totals_at(index)
      frame = @simulation.frames.fetch(index)
      {
        "showcase-mason" => base(:mason) + self.class.points(frame.game.home_score, @home.turf_score),
        "showcase-turf" => base(:turf) + self.class.points(frame.game.away_score, @away.turf_score),
        "showcase-mack" => base(:mack)
      }
    end

    def leader_at(index) = totals_at(index).max_by { |_, total| total }.first

    # The three entrants at frame `index`, highest total first.
    def entries_at(index)
      frame = @simulation.frames.fetch(index)
      [
        build_entry(ENTRANTS[0], @hands[0].first(PICKS - 1), @goals[:mason], [@home, frame.game.home_score]),
        build_entry(ENTRANTS[1], @hands[1].first(PICKS - 1), @goals[:turf], [@away, frame.game.away_score]),
        build_entry(ENTRANTS[2], @hands[2].first(PICKS), @goals[:mack], nil)
      ].sort_by { |entry| -entry.score.to_f }
    end

    private

    def base(who)
      hand = who == :mack ? @hands[2].first(PICKS) : @hands[who == :mason ? 0 : 1].first(PICKS - 1)
      hand.zip(@goals[who]).sum { |m, g| self.class.points(g, m.turf_score) }
    end

    # Mason leads the opening frame and every frame his team just scored in;
    # turf leads every frame hers did.
    def mason_frames = @simulation.frames.select { |f| f.team.nil? || f.team.slug == @home.team_slug }
    def turf_frames = @simulation.frames.select { |f| f.team&.slug == @away.team_slug }

    # Mason minus turf = gap + home points - away points, so the gap must sit
    # above (away - home) on Mason's frames and below it on turf's.
    def margin(frame) = self.class.points(frame.game.away_score, @away.turf_score) - self.class.points(frame.game.home_score, @home.turf_score)

    def balance!
      lo = mason_frames.map { |f| margin(f) }.max
      hi = turf_frames.map { |f| margin(f) }.min
      return false if hi.nil? || lo.nil? || hi <= lo

      best = nil
      %i[mason turf].each do |who|
        (0..80).each do |g|
          @goals[who][PICKS - 2] = g
          gap = base(:mason) - base(:turf)
          room = [gap - lo, hi - gap].min
          best = [room, who, g] if room.positive? && (best.nil? || room > best[0])
        end
        @goals[who][PICKS - 2] = (who == :mason ? MASON_BASE : TURF_BASE)[PICKS - 2]
      end
      return false unless best

      @goals[best[1]][PICKS - 2] = best[2]
      true
    end

    def hold_mack_under!
      floor = @simulation.frames.each_index.map { |i| totals_at(i).values_at("showcase-mason", "showcase-turf").min }.min
      4.times do
        return true if base(:mack) < floor - 0.5

        @goals[:mack] = @goals[:mack].map { |g| g / 2 }
      end
      @goals[:mack] = [0] * PICKS
      base(:mack) < floor
    end

    def build_entry(entrant, hand, goals, featured)
      user = User.new(username: entrant[:name]).tap(&:readonly!)
      entry = Entry.new(slug: entrant[:slug], status: "active")
      entry.association(:contest).target = @contest
      entry.association(:user).target = user
      picks = hand.zip(goals)
      picks << featured if featured
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
