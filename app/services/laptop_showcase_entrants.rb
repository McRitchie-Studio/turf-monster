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
# ORDER. Real entries and showcase entrants are ranked together by score, the
# board's own order; ties keep real entries first, then Mason, turf, mack.
# With 3 or more real entries nothing changes.
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

    real = showcase.entries
    ranked = (real + showcase_entries).each_with_index
                                      .sort_by { |entry, i| [-entry.score.to_f, i] }
                                      .map(&:first)
    showcase.with(entries: ranked)
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
end
