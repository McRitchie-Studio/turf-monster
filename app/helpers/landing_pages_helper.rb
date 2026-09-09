module LandingPagesHelper
  # Sport label for funnel copy, keyed by `Slate#sport`.
  FUNNEL_SPORT_LABELS = { "nfl" => "NFL", "fifa" => "World Cup" }.freeze

  # The sport this funnel is selling, or nil when there is nothing to read it
  # from.
  #
  # TWO INDEPENDENT AXES, and conflating them is the whole history of this file:
  #
  #   FORMAT  `contest.game_type` — a two-value enum (contest.rb): turf_totals or
  #           world_cup_survivor. It picks WHICH STEPS the funnel shows.
  #   SPORT   `contest.slate.sport` — "nfl" or "fifa". It picks the WORDS inside
  #           the Turf Totals steps.
  #
  # The format says nothing about the sport: Turf Totals ran on the World Cup in
  # season 1 and runs on the NFL now. So hardcoding EITHER sport in the Turf
  # Totals branch is right for one audience and wrong for the other. This file
  # has been wrong in both directions — World Cup hardcoded (shipped), then NFL
  # hardcoded (caught at review, when 100 percent of live funnels were fifa).
  # Derive it; do not hardcode a third time.
  #
  # NIL IS ADMIN-ONLY, and two validations are what make that true:
  #   * LandingPage#contest_required_when_active — a page cannot be ACTIVE
  #     without a contest, so every public visitor has one.
  #   * Contest `validates :slate, presence: true, if: :turf_totals?` — every
  #     Turf Totals contest carries a slate, so the branch that reads this label
  #     always has one.
  # Together they leave exactly one nil path: an admin previewing a draft page
  # with no contest wired yet. `Slate#sport` itself never answers nil — it reads
  # the column and falls back to `Slate.sport_from_name(name)`, which answers
  # "fifa" for any name that does not say NFL.
  def funnel_sport(contest)
    contest&.slate&.sport
  end

  def funnel_sport_label(contest)
    FUNNEL_SPORT_LABELS[funnel_sport(contest)]
  end

  # Funnel "how it works" steps: the format picks the steps, the sport picks the
  # words. This page is public and unauthenticated (landing_pages_controller.rb
  # skips require_authentication), so keep calendar dates and rehearsal
  # vocabulary out of the copy — both rot in front of real visitors.
  def funnel_how_it_works(contest)
    if contest&.world_cup_survivor?
      [
        ["Enter the contest", "One entry per player — claim your spot before the tournament locks."],
        ["Pick a team each round", "Back a different team every round. No team can be used twice."],
        ["Win or draw to survive", "A loss eliminates you. The last player standing takes the prize."]
      ]
    else
      required_picks = contest&.picks_required || Contest::TURF_TOTALS_DEFAULT_PICKS_REQUIRED
      # "World Cup team matchups" / "NFL team matchups" / "team matchups" when
      # there is no sport to name. The sportless form is still a true sentence,
      # which is the point: it names no sport rather than guessing one.
      subject = [funnel_sport_label(contest), "team matchups"].compact.join(" ")
      [
        ["Pick #{required_picks} teams", "Choose #{required_picks} #{subject} for your entry."],
        ["Create Account", "Sign up with email or Google — it only takes a few seconds."],
        ["Submit Entry", "Confirm your #{required_picks} picks and submit your entry."],
        # THE LOCK MOMENT IS THE CONTEST'S START TIME, NOT A KICKOFF.
        # Contest#locks_at is `starts_at || slate.first_game_starts_at ||
        # slate.starts_at` (contest.rb:686-693): an explicit starts_at WINS, it
        # is admin-permitted on create AND edit, and nothing validates it
        # against the slate's first kickoff. So the two moments are equal in TWO
        # cases, not one: when an admin leaves starts_at blank and the
        # derivation falls through to that kickoff, and when an admin SETS
        # starts_at to exactly that kickoff — legal, unvalidated, and what the
        # World Cup rulebook's worked example depicts (a lock and a first
        # kickoff both 3pm). Any OTHER explicit starts_at splits them, which is
        # the case this sentence exists to survive; turf_totals_lock_rule_test.rb
        # measures all three against Contest.
        #
        # This step said "when the first game kicks off" until 2026-09-08, and
        # on production that day three of seven contests had locked EARLIER than
        # their first kickoff — one by 8.6 days. On a pre-payment page, that
        # overstates how long a visitor may ENTER: they wait for kickoff and
        # find the door shut.
        #
        # "its start time" is the value the card above this list already prints
        # (Contest#lock_time_display -> starts_in_at -> the same attribute
        # locks_at reads), so the sentence points at a time on the same screen
        # and stays true however that time was set.
        #
        # BOTH DOORS SHUT AT ONCE, for both sports: every write path refuses
        # after locks_at — Entry#toggle_selection! (entry.rb:47), #update_picks!
        # (entry.rb:81) and #assert_enterable! (entry.rb:134) each raise
        # "Contest has locked — entries closed". Not just picks whose own game
        # has kicked off: the per-game SlateMatchup#locked? check is a SEPARATE,
        # additional guard, and is NOT what this sentence rests on — an earlier
        # version of this comment cited that guard, and a method that does not
        # exist, for a conclusion that was nonetheless right.
        # turf_totals_lock_rule_test.rb pins every entry.rb line cited here to a
        # contest-wide lock guard, and measures the entry door against a contest
        # that locks before any game kicks off.
        ["Contest Locks", "The contest locks at its start time. No entries or changes after that."]
      ]
    end
  end

  # The rulebook this funnel should open. Two versioned rules pages, ONE PER
  # SEASON (routes.rb): turf-totals-v1 documents the World Cup format and is
  # still badged "World Cup 2026"; turf-monster-v1 documents the NFL format.
  # Sending a visitor to the other sport's book is the copy defect again, one
  # click later in the same journey.
  def funnel_rulebook_path(contest)
    return turf_totals_v1_path if funnel_sport(contest) == "fifa"

    # NFL, and the sportless admin preview. turf-monster-v1 is also the sitewide
    # canonical "Rules" target (navbar, footer, transparency hub), so a draft
    # with no contest agrees with the chrome around it.
    turf_monster_v1_path
  end
end
