class Contest
  # WHEN A CONTEST'S ENTRIES CLOSE when nobody set a lock by hand.
  #
  # The one home of the rule. Slate#default_contest_lock_at (the model, one
  # slate) and Api::V1::ContestFacts#locks_at (a page of contests in two grouped
  # queries) both call it, so the two cannot drift; and every create path stamps
  # its result into `contests.starts_at` through ContestsController
  # #default_start_for_slate, which is how it reaches the chain's lock_timestamp.
  #
  # NON-NFL (World Cup and anything else): the first kickoff, exactly as before.
  #
  # NFL: 11:00 AM America/Denver on the slate's OPENING SUNDAY —
  # the 1 PM ET window, which is when a week's slate really starts. Thursday
  # Night Football used to lock the whole contest on Thursday. Precisely:
  #
  #   1. Opening Sunday = the first Sunday on or after the first kickoff's DATE,
  #      read in America/Denver.
  #   2. Lock = that Sunday at 11:00 America/Denver. A zone, not a fixed offset,
  #      so it stays on 1 PM ET across the DST change (17:00Z in October, 18:00Z
  #      in November).
  #   3. Never EARLIER than the first kickoff — a Sunday-night-only slate locks
  #      at its own kickoff, not five hours before it.
  #   4. Never LATER than the slate's LAST kickoff, because without it a slate
  #      with no game on or after that Sunday (a Thursday-only or Saturday-only
  #      slate) would stay open after every game in it had started. A span slate's last kickoff is weeks out, so this
  #      never bites there. Rule 3 wins over rule 4: they only meet on a slate
  #      whose games all fall before the Sunday, and then it locks at the first.
  #
  # Teams whose game kicks off BEFORE this lock (TNF, London, Saturday) are
  # closed one by one at their own first kickoff: SlateMatchup#pick_locked?,
  # enforced by every pick writer in Entry.
  module LockRule
    ZONE = "America/Denver".freeze
    NFL_LOCK_HOUR = 11

    module_function

    # sport          — Slate#sport ("nfl", "fifa", ...)
    # first_kickoff  — the slate's earliest game kickoff (nil when no game has a time)
    # last_kickoff   — the slate's latest game kickoff (nil allowed)
    # fallback       — the slate's own starts_at, used when no game has a time
    def default_lock_at(sport:, first_kickoff:, last_kickoff: nil, fallback: nil)
      anchor = first_kickoff || fallback
      return anchor unless sport.to_s == "nfl" && anchor

      nfl_lock_at(anchor, last_kickoff: last_kickoff)
    end

    def nfl_lock_at(first_kickoff, last_kickoff: nil)
      zone = ActiveSupport::TimeZone[ZONE]
      date = first_kickoff.in_time_zone(zone).to_date
      sunday = date + ((7 - date.wday) % 7)
      lock = zone.local(sunday.year, sunday.month, sunday.day, NFL_LOCK_HOUR)
      lock = [lock, last_kickoff].min if last_kickoff
      [lock, first_kickoff].max
    end
  end
end
