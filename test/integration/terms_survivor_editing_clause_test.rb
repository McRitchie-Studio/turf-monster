require "test_helper"

# The Terms of Service "Editing your entry" clause (app/views/pages/terms.html.erb)
# told every reader, on a public real-money page, that "Survivor entries do not
# support editing".
#
# THE CODE SAYS THE OPPOSITE. ContestsController#pick is headed "submit or
# replace this entry's pick for a round": it reaches for
# `entry.survivor_picks.find_or_initialize_by(survivor_round: round)`, assigns
# `team_slug`, and saves. The ONLY refusal on that path is
# `round.picks_locked?`. The product UI already publishes the truth — the
# survivor board renders "Pick saved - you can change it until the round locks."
#
# ROOT CAUSE. The sentence transcribed a DEFENSIVE BACKSTOP as a user-facing
# promise. Entry#update_picks! does raise "Editing is not supported for this
# contest type" for a survivor entry, but that method has exactly one app
# caller - the Turf Totals edit path in EntriesController - which no survivor
# user ever reaches.
#
# So this guard does NOT grep for the replacement sentence. Grepping is how the
# false one survived: four assertions in turf_totals_lock_rule_test.rb are
# anchored on this very clause, and every one of them passed with the false
# sentence intact, because each asks about the Turf Totals half. This test
# MEASURES the survivor edit window through the real path a player uses - the
# contest page's POST - and requires the published copy to agree with the
# measurement. Close the survivor edit path and the measurement flips, and this
# test demands the old wording come back onto the page.
#
# The Turf Totals half of the clause, including the kicked-off carve-out, is
# measured separately in turf_totals_lock_rule_test.rb. This file owns only the
# Survivor sentence.
class TermsSurvivorEditingClauseTest < ActionDispatch::IntegrationTest
  setup do
    # A plain entrant, not the admin fixture: the clause binds the operator to
    # the person paying to play, and #pick has no admin path to fall into.
    @user = users(:jordan)

    @first = make_team("survivor-clause-first")
    @second = make_team("survivor-clause-second")
    @third = make_team("survivor-clause-third")
    @fourth = make_team("survivor-clause-fourth")

    # Locked by TIME, not by flipping `status`. "until their round locks" is a
    # claim about picks_lock_at passing, which is the lock a player actually
    # runs into, so that is the one the measurement crosses.
    @round = SurvivorRound.create!(number: 91, name: "Survivor Clause Round",
                                   stage: "group", status: "upcoming",
                                   picks_lock_at: 2.hours.from_now)

    # #pick refuses a team that is not playing in the round, so every team the
    # measurement reaches for needs a fixture in it.
    make_game(@first, @second)
    make_game(@third, @fourth)

    @contest = Contest.create!(name: "Survivor Clause Contest",
                               slug: "survivor-clause-contest",
                               game_type: "world_cup_survivor",
                               contest_type: "survivor_wc_free",
                               entry_fee_cents: 0, max_entries: 59, status: "open")

    @entry = Entry.create!(user: @user, contest: @contest, status: "active")
    log_in_as(@user)
  end

  # ── the measurement ───────────────────────────────────────────────────────

  # Submit `team` for the round through the REAL path the clause describes -
  # the contest page's POST, in the JSON shape the survivor board sends - and
  # answer with the STORED FACT, not the response flag. A 200 that wrote
  # nothing is not an edit, and this question is only ever "is the pick now
  # this team".
  def pick_accepted?(team)
    post pick_contest_path(@contest),
         params: { round_id: @round.id, team_slug: team.slug }, as: :json

    # #pick renders its own JSON on both outcomes: 200 on success, 422 on every
    # refusal. Anything else means the request never reached the action - an
    # auth bounce, an expired session after the time travel below, a contest
    # miss - and a "refusal" read off one of those is not the lock talking.
    assert_includes [200, 422], response.status,
                    "measurement: ContestsController#pick must have handled the request; " \
                    "got #{response.status}, which is not one of its own renders"

    stored_pick&.team_slug == team.slug
  end

  def stored_pick
    SurvivorPick.find_by(entry: @entry, survivor_round: @round)
  end

  # The window the sentence describes, measured at two instants on ONE round:
  #
  #   submitted  - CONTROL. An INITIAL pick, accepted and stored. It proves the
  #                harness can produce an ACCEPT at all: auth, the entry, the
  #                contest, the round, and the fixtures are all good. Without
  #                it, a refusal below could come from an eliminated entry or a
  #                team that is not in the round, and this test would certify
  #                any Terms copy at all. It exercises #pick's CREATE branch,
  #                so closing only the REPLACE branch leaves it green - which
  #                is what keeps the else branch below reachable rather than
  #                dead code.
  #
  #   replaced   - THE CLAIM. A DIFFERENT team, same round, round still
  #                unlocked, and the stored pick moves to it.
  #
  #   held       - THE BOUNDARY. Past picks_lock_at, a third team is refused
  #                AND the stored pick still names the second: refused, not
  #                destroyed.
  def survivor_pick_edit_window
    refute @round.picks_locked?,
           "measurement: the round must NOT be locked yet - this is the window before the lock"

    submitted = pick_accepted?(@first)
    replaced = pick_accepted?(@second)

    held = nil
    travel_to @round.picks_lock_at + 1.minute do
      assert @round.picks_locked?,
             "measurement: picks_lock_at has passed, so the round must read as locked"

      held = !pick_accepted?(@third) && stored_pick&.team_slug == @second.slug
    end

    [submitted, replaced, held]
  end

  # Scope to the clause's own subtree. An unscoped css_select reads the LAYOUT
  # too - nav, footer, flash - so a match proves nothing about this clause. And
  # a selector that matches nothing yields "" and passes every refute_match
  # having read no copy at all, so the node is asserted before its text is.
  #
  # SQUISHED, because the ERB source wraps mid-sentence and the raw node text
  # carries those newlines plus their indentation: "...until their round\n
  # locks". A browser collapses all of it, so the squished string is what a
  # reader of the binding page actually sees - and the assertions below then
  # survive a re-wrap of the paragraph, which is not a change to its meaning.
  def editing_clause
    node = css_select('[data-test="terms-entry-editing"]').first
    assert node, "Terms must render a terms-entry-editing subtree to scope the clause against"
    node.text.squish
  end

  test "the Terms survivor clause matches the edit window ContestsController#pick enforces" do
    submitted, replaced, held = survivor_pick_edit_window

    # CONTROL - see survivor_pick_edit_window.
    assert submitted,
           "control: an initial survivor pick on an unlocked round must be ACCEPTED and stored. " \
           "Without that, every refusal below is the harness talking rather than the edit path, " \
           "and this test would certify any wording"

    get terms_path
    assert_response :success
    clause = editing_clause

    assert_match(/survivor/i, clause,
                 "the binding editing clause must say what a Survivor entrant may do - the " \
                 "contest page lets them change a pick, so silence here is its own defect")

    if replaced
      # MEASURED REALITY. #pick REPLACED a stored survivor pick with a different
      # team while the round was unlocked. The binding page may not tell a
      # paying entrant the opposite of what the code just did.
      refute_match(/survivor[^.]*not support editing/i, clause,
                   "ContestsController#pick replaced this entry's stored survivor pick with a " \
                   "second team while the round was unlocked, so Terms may not tell a paying " \
                   "entrant that Survivor entries do not support editing")
      refute_match(/survivor[^.]*cannot be (?:changed|edited|replaced)/i, clause,
                   "the survivor pick WAS changed through the contest page, so the clause may " \
                   "not say it cannot be")
      assert_match(/survivor[^.]*can be changed/i, clause,
                   "the clause must state the editing window the code actually grants a " \
                   "Survivor entrant, not leave them reading the Turf Totals rule")

      if held
        # The lock is a real boundary: past picks_lock_at the replace was
        # refused and the stored pick was left alone. The clause must name it,
        # or "can be changed" reads as open-ended on a real-money page.
        assert_match(/survivor[^.]*round locks/i, clause,
                     "past picks_lock_at #pick REFUSED the replace and left the stored pick " \
                     "untouched, so the clause must bound the editing window at the round lock")
      else
        # The round lock stopped ending the window. Naming it would then be a
        # boundary that does not exist.
        refute_match(/survivor[^.]*round locks/i, clause,
                     "the round lock no longer ends the survivor editing window, so Terms may " \
                     "not publish it as the boundary")
      end
    else
      # The survivor edit path is closed: an initial pick still lands (the
      # control held) but a replace no longer does. The old sentence becomes
      # TRUE, and a binding page that promises an edit the code refuses is the
      # more dangerous of the two errors - so demand the wording back.
      assert_match(/survivor[^.]*(?:not support editing|cannot be (?:changed|edited|replaced))/i,
                   clause,
                   "#pick accepted an initial survivor pick but REFUSED to replace it on an " \
                   "unlocked round, so the survivor edit path is closed - Terms must stop " \
                   "promising an edit the code will not perform")
    end
  end

  private

  def make_team(slug)
    Team.create!(slug: slug, name: slug.titleize, short_name: slug[-3..].upcase,
                 location: slug.titleize, emoji: "🏳️",
                 color_dark: "#111111", color_light: "#222222")
  end

  def make_game(home, away)
    Game.create!(home_team_slug: home.slug, away_team_slug: away.slug,
                 survivor_round: @round, status: "scheduled")
  end
end
