class Contest
  # WHICH OF A CONTEST'S GAMES BELONG ON THE LIVE BOARD RIGHT NOW.
  #
  # A span contest covers several NFL weeks (Weeks 4-6 is three), and its slate
  # holds every game of every one of them. The live board used to draw them all:
  # next week's DET-ARI sat in the strip beside tonight's DET-CAR at 0-0, and the
  # carousel rotated through games nobody could watch for seven days.
  #
  # THE WEEK (Alex, 2026-10-04): it turns over on Tuesday at 7:00 AM Denver. Not
  # at midnight Monday, because Monday Night Football is still being talked
  # about then; by Tuesday morning the week that matters is the next one. A
  # zone, not a fixed offset, so the turn stays at 7 on the wall clock across
  # the DST change.
  #
  # Kickoff time decides membership, not `games.week`. That column is stamped by
  # the score poller, so a game the poller has not reached yet carries a null
  # week — and the games of a week that has not started are exactly those.
  #
  # NEVER AN EMPTY BOARD. When the current week holds none of the contest's
  # games (it has not started yet, a bye in the span, or it is over), the board
  # shows the NEXT week that has some, and failing that the last one that did.
  #
  # A game with no kickoff time cannot be placed in any week, so it rides along
  # with whichever week is showing rather than vanishing.
  module WeekWindow
    ZONE = "America/Denver".freeze
    START_WDAY = 2 # Tuesday
    START_HOUR = 7

    module_function

    # The start of the week that contains `time`.
    def start_for(time)
      local = time.in_time_zone(ZONE)
      start = local.beginning_of_day + START_HOUR.hours
      start -= 1.day until start.wday == START_WDAY && start <= local
      start
    end

    # The games to show at `now`: the current week's, else the nearest week's.
    def current(games, now = Time.current)
      timed, untimed = games.partition { |game| game.kickoff_at.present? }
      weeks = timed.group_by { |game| start_for(game.kickoff_at) }
      return games if weeks.empty?

      this_week = start_for(now)
      shown = weeks[this_week] ||
              weeks[weeks.keys.select { |start| start > this_week }.min] ||
              weeks[weeks.keys.max]

      shown + untimed
    end
  end
end
