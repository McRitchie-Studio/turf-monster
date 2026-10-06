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

  def self.enterable_at?(contest, now)
    at = contest.locks_at
    at.nil? || at > now
  end
end
