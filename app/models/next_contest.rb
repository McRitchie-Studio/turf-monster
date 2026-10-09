# What the /turf-monster-v2 call to action does: send the visitor to the next
# NFL contest they can still enter, or, when there is none, open the notify-me
# modal for the next slate drop (NextSlateDrop).
#
# ENTERABLE MEANS ALL OF: status open, not coming soon, not cancelled on chain,
# and its lock still ahead. The lock test is the point of this object.
# EntryGift#landing_contest falls back to Contest.featured, which checks no
# lock at all, so a gift can land on a contest whose doors have shut; this
# never repeats that. A contest with no lock at all (manual-only, never
# derived-locked; Contest#locked?) is enterable, and sorts after every dated
# one.
#
# NEXT means the soonest lock: the contest a visitor has to act on first.
module NextContest
  Pick = Data.define(:contest) do
    def link? = !contest.nil?
    def modal? = contest.nil?
  end

  def self.pick(now: Time.current)
    candidates = Contest.open.where(coming_soon: false)
                        .joins(:slate).where(slates: { sport: "nfl" })
                        .includes(:slate)
                        .reject(&:cancelled?)
                        .select { |contest| enterable_at?(contest, now) }
    Pick.new(contest: candidates.min_by { |c| [c.locks_at ? 0 : 1, c.locks_at || now, c.id] })
  end

  # The "Watch updates live" link under /turf-monster-v2's hero laptop: the
  # NFL contest being played right now (locked, not settled), else the one that
  # finished most recently. nil when there is neither, and the page draws no
  # link. Only the link reads it: the laptop itself shows a FICTIONAL contest
  # (LaptopFictionalShowcase), never this one.
  def self.live_contest
    nfl = Contest.listed.where(coming_soon: false)
                 .joins(:slate).where(slates: { sport: "nfl" })
                 .includes(:slate).to_a
                 .reject(&:cancelled?).select(&:turf_totals?)
    playing  = nfl.select(&:live?).max_by { |c| c.locks_at || c.created_at }
    finished = nfl.select(&:concluded?).max_by { |c| c.concludes_at || c.locks_at || c.created_at }
    playing || finished
  end

  def self.enterable_at?(contest, now)
    at = contest.locks_at
    at.nil? || at > now
  end
end
