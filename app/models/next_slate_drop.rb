# The next slate the /turf-monster-v2 explainer is counting down to.
#
# ONE PLACE TO CHANGE IT. The page's countdown, its "notify me" form and the
# DropSignup rows it writes all read this module, so moving the drop (or rolling
# the page on to the next slate) is an edit here and nowhere else:
#
#   SLATE_KEY  the key every DropSignup row is filed under, so the table can
#              collect the NEXT drop's list without mixing it with this one's
#   LABEL      how the page names the slate in its copy
#   DROPS_AT   the instant the slate goes live
#
# THE INSTANT IS BUILT FROM A WALL CLOCK, NOT FROM ARITHMETIC. Alex set it as
# "Tuesday morning, Mountain time", so it is written down as exactly that — a
# date, an hour, a zone — and resolved through the zone's own rules. Midnight
# plus N hours is NOT N o'clock on a DST-change day (the fall-back Sunday lands
# an hour early, spring-forward an hour late), which is the bug
# Contest::WeekWindow shipped once. `.wall_clock` uses `change(hour:)`, and
# test/models/next_slate_drop_test.rb asserts on the transition day itself.
module NextSlateDrop
  ZONE = "America/Denver".freeze

  SLATE_KEY = "nfl-2026-weeks-7-9".freeze
  LABEL = "Weeks 7-9".freeze

  # The drop's wall clock, then the instant: 8:00 AM Mountain on Tuesday
  # 2026-10-20. Mountain is on daylight time that day (UTC-6), so this is
  # 14:00 UTC.
  DROP_DATE = Date.new(2026, 10, 20)
  DROP_HOUR = 8

  # `hour` o'clock on `date`, on the wall clocks in ZONE.
  def self.wall_clock(date, hour)
    Time.find_zone!(ZONE).local(date.year, date.month, date.day).change(hour: hour)
  end

  DROPS_AT = wall_clock(DROP_DATE, DROP_HOUR)

  # The campaign the drop announcement's links carry (?reference=), so a click
  # from that email is told apart from every other way in. Swap to ?r= when the
  # short param lands (sibling task); the value stays.
  EMAIL_REFERENCE = "email-drop-w7".freeze

  def self.drops_at
    DROPS_AT
  end

  # How the emails name the moment, on Mountain wall clocks:
  # "Tuesday, October 20 at 8:00 AM MDT". The zone abbreviation comes from the
  # zone's own rules, so a drop after the fall-back reads MST.
  def self.drops_at_label
    DROPS_AT.in_time_zone(ZONE).strftime("%A, %B %-d at %-l:%M %p %Z")
  end

  # LABEL with a typographic en dash, for email copy ("Weeks 7–9").
  def self.display_label
    LABEL.tr("-", "\u2013")
  end

  def self.dropped?(now = Time.current)
    now >= DROPS_AT
  end

  # Whole days, hours and minutes until the drop, floored at zero — the same
  # split the page's Alpine countdown makes, so the server-rendered fallback
  # and the first JS tick agree.
  def self.remaining(now = Time.current)
    seconds = [(DROPS_AT - now).to_i, 0].max
    { days: seconds / 86_400, hours: (seconds % 86_400) / 3600, minutes: (seconds % 3600) / 60 }
  end
end
