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

  # The laptop on /turf-monster-v2's hero: the contests lobby, live. Up to
  # `limit` contests a visitor could act on, in the lobby's own order
  # (Contest.featured_order: open first, then coming soon, newest first), plus
  # their confirmed entry counts in ONE grouped query, so the real
  # contests/_contest_card can draw them with no per-card query.
  #
  # Same rule as .pick about doors: a contest whose lock has passed, or that is
  # cancelled or settled, is never shown, since the lobby card would present it
  # as enterable. A coming-soon contest IS shown; its card carries the
  # "Coming Soon" sash. Any sport, because it is the whole lobby.
  Lobby = Data.define(:contests, :entry_counts) do
    def empty? = contests.empty?
  end

  LOBBY_LIMIT = 3

  def self.lobby(limit: LOBBY_LIMIT, now: Time.current)
    recent = Contest.open.includes(:slate).with_attached_contest_image
                    .order(created_at: :desc).limit(limit * 4).to_a
    shown = Contest.featured_order(recent.select { |c| enterable_at?(c, now) }).first(limit)
    counts = shown.empty? ? {} : Entry.confirmed.where(contest_id: shown.map(&:id)).group(:contest_id).count
    Lobby.new(contests: shown, entry_counts: counts)
  end

  # The laptop on /turf-monster-v2's hero shows a contest's LIVE page: the NFL
  # contest being played right now (locked, not settled), else the one that
  # finished most recently. nil when there is neither; the laptop then falls
  # back to the lobby list.
  #
  # Everything the snapshot draws, loaded here so the view issues no query of
  # its own: the games in the live page's three phases (Contest#games_by_phase,
  # the same buckets ContestsController#live uses), the game the page would
  # open on, and the top `leaders` entries with their users preloaded.
  LiveShowcase = Data.define(:contest, :games, :focus_slug, :leaders) do
    def live? = contest.live?
  end

  def self.live_showcase(now: Time.current, leaders: 3)
    nfl = Contest.where(status: [:open, :settled], coming_soon: false)
                 .joins(:slate).where(slates: { sport: "nfl" })
                 .includes(:slate).to_a
                 .reject(&:cancelled?).select(&:turf_totals?)
    playing  = nfl.select(&:live?).max_by { |c| c.locks_at || c.created_at }
    finished = nfl.select(&:concluded?).max_by { |c| c.concludes_at || c.locks_at || c.created_at }
    contest = playing || finished
    return nil unless contest

    games = contest.games_by_phase(now)
    focus = (games[:active].first || games[:upcoming].first || games[:completed].first)&.slug
    top = contest.entries.where(status: [:active, :complete]).includes(:user)
                 .order(score: :desc, id: :asc).limit(leaders).to_a
    LiveShowcase.new(contest: contest, games: games, focus_slug: focus, leaders: top)
  end

  def self.enterable_at?(contest, now)
    at = contest.locks_at
    at.nil? || at > now
  end
end
