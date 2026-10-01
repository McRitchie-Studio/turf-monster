require "test_helper"

# On a span ("Weeks 1-2") contest a pick is a TEAM, anchored on the team's first
# game (Contest#pickable_matchups). The slate still holds a row for every later
# game, and those rows are real SlateMatchups with real ids, so a hand-built
# request can name one. These tests pin that neither pick path accepts such a
# row, and that one entry can never hold the same team twice.
class SpanPickGuardTest < ActiveSupport::TestCase
  include SpanContestBuilder

  TEAMS = %w[team-a team-b team-c team-d team-e team-f].freeze

  setup do
    @contest = build_span_contest!(contests(:one))
    @entry = @contest.entries.create!(user: users(:sam), status: :cart)
  end

  def anchor(team) = span_row(@contest, team, week: 1)
  def later(team)  = span_row(@contest, team, week: 2)

  test "the fixture is a span: twelve rows, six pickable, six picks required" do
    assert @contest.multi_week?
    assert_equal 12, @contest.matchups.count
    assert_equal TEAMS.map { |t| anchor(t).id }.sort, @contest.pickable_matchups.map(&:id).sort
    assert_equal 6, @contest.picks_required
  end

  # Contest#pickable_matchup_ids is a one-read spelling of pickable_matchups, and
  # every guard below leans on the two agreeing — on both slate shapes.
  test "pickable_matchup_ids agrees with pickable_matchups on a span and a single week" do
    assert_equal @contest.pickable_matchups.map(&:id).sort, @contest.pickable_matchup_ids.sort

    single = contests(:one).tap { |c| c.update!(slate: slates(:one)) }
    assert_not single.multi_week?
    assert_equal single.matchups.pluck(:id).sort, single.pickable_matchup_ids.sort
    assert_equal single.pickable_matchups.map(&:id).sort, single.pickable_matchup_ids.sort
  end

  # --- toggle -------------------------------------------------------------

  test "toggle refuses a later-week row of a team" do
    error = assert_raises(RuntimeError) { @entry.toggle_selection!(later("team-a")) }

    assert_match(/not a pickable/i, error.message)
    assert_equal 0, Selection.where(entry_id: @entry.id).count
  end

  test "toggle refuses a later-week row of a team already held" do
    @entry.toggle_selection!(anchor("team-a"))

    error = assert_raises(RuntimeError) { @entry.toggle_selection!(later("team-a")) }

    assert_match(/not a pickable/i, error.message)
    assert_equal [ anchor("team-a").id ], @entry.selections.reload.map(&:slate_matchup_id)
  end

  # The per-game lock reads the row's OWN game. Once week one has kicked off,
  # the week-two row of the same team is still "unlocked" — so without the
  # pickable guard a team could be added after its first game was already live.
  test "toggle refuses a later-week row after the team's first game kicked off" do
    Game.where(slug: @contest.matchups.where(week: 1).select(:game_slug)).update_all(kickoff_at: 1.hour.ago)
    row = later("team-a")

    assert anchor("team-a").locked?, "the team's first game is live"
    assert_not row.locked?, "the later row's own game has not started"
    assert @contest.locks_at > Time.current, "the contest-wide lock has not caught it either"
    assert_raises(RuntimeError) { @entry.toggle_selection!(row) }
    assert_equal 0, Selection.where(entry_id: @entry.id).count
  end

  test "toggle still accepts every pickable row" do
    TEAMS.each { |team| @entry.toggle_selection!(anchor(team)) }

    assert_equal 6, @entry.selections.reload.count
  end

  # A refused seventh pick must not cost the player their oldest one: the
  # replace-oldest branch destroys before it creates.
  test "a refused pick on a full cart leaves the cart intact" do
    TEAMS.each { |team| @entry.toggle_selection!(anchor(team)) }
    before = @entry.selections.reload.map(&:slate_matchup_id).sort

    assert_raises(RuntimeError) { @entry.toggle_selection!(later("team-b")) }

    assert_equal before, @entry.selections.reload.map(&:slate_matchup_id).sort
  end

  # The same branch, refused one step later: the row IS pickable, so the gate
  # above lets it through, and the create is what refuses it. A cart built
  # before the pick writers were gated can hold a team by its later-week row;
  # adding that team's anchor row then breaks one-team-per-entry
  # (Selection#team_unique_within_entry) AFTER the oldest pick was destroyed.
  test "a pick refused by the create on a full cart leaves the cart intact" do
    (TEAMS - %w[team-a]).each { |team| @entry.selections.create!(slate_matchup: anchor(team)) }
    @entry.selections.create!(slate_matchup: later("team-a")) # the legacy row, and the newest
    before = @entry.selections.reload.map(&:slate_matchup_id).sort
    assert_equal 6, before.size

    error = assert_raises(ActiveRecord::RecordInvalid) { @entry.toggle_selection!(anchor("team-a")) }

    assert_match(/already picked/i, error.message)
    assert_equal before, Selection.where(entry_id: @entry.id).pluck(:slate_matchup_id).sort,
                 "the oldest pick was destroyed for a pick that was then refused"
  end

  # --- update_picks! ------------------------------------------------------

  test "update_picks refuses a set carrying a later-week row" do
    @entry.update!(status: :active)
    TEAMS.each { |team| @entry.selections.create!(slate_matchup: anchor(team)) }
    before = @entry.selections.reload.map(&:slate_matchup_id).sort

    # Six distinct row ids, five teams: team-a twice (weeks one and two).
    ids = (TEAMS - %w[team-f]).map { |team| anchor(team).id } + [ later("team-a").id ]
    error = assert_raises(RuntimeError) { @entry.update_picks!(ids) }

    assert_match(/invalid matchup/i, error.message)
    assert_equal before, @entry.selections.reload.map(&:slate_matchup_id).sort
  end

  test "update_picks refuses a later-week row standing in for its team" do
    @entry.update!(status: :active)
    TEAMS.each { |team| @entry.selections.create!(slate_matchup: anchor(team)) }

    # Six teams, but team-f is named by its week-two row.
    ids = (TEAMS - %w[team-f]).map { |team| anchor(team).id } + [ later("team-f").id ]

    assert_raises(RuntimeError) { @entry.update_picks!(ids) }
    assert_includes @entry.selections.reload.map(&:slate_matchup_id), anchor("team-f").id
  end

  test "update_picks still accepts six pickable rows" do
    @entry.update!(status: :active)
    (TEAMS - %w[team-f]).each { |team| @entry.selections.create!(slate_matchup: anchor(team)) }
    @entry.selections.create!(slate_matchup: anchor("team-f"))

    @entry.update_picks!(TEAMS.map { |team| anchor(team).id })

    assert_equal 6, @entry.selections.reload.count
  end

  # --- the model guard ----------------------------------------------------

  test "one entry cannot hold the same team twice" do
    Selection.create!(entry: @entry, slate_matchup: anchor("team-a"))
    second = Selection.new(entry: @entry, slate_matchup: later("team-a"))

    assert_not second.valid?
    assert_match(/already/i, second.errors.full_messages.to_sentence)
    assert_raises(ActiveRecord::RecordInvalid) { second.save! }
  end

  test "the same team on a DIFFERENT entry is fine" do
    other = @contest.entries.create!(user: users(:jordan), status: :cart)
    Selection.create!(entry: @entry, slate_matchup: anchor("team-a"))

    assert Selection.new(entry: other, slate_matchup: anchor("team-a")).valid?
  end

  # Scoring writes `points` through update!, so the team guard must not fire on
  # a row whose pick did not change — otherwise grading a slate would raise.
  test "re-scoring an existing selection does not re-run the team guard" do
    selection = Selection.create!(entry: @entry, slate_matchup: anchor("team-a"))
    anchor("team-a").update!(goals: 2)

    assert_nothing_raised { selection.compute_points! }
    assert_equal 4.0, selection.reload.points.to_f, "2 goals x 2.0, counted once"
  end

  # --- the gate before money ----------------------------------------------

  test "an entry holding a non-pickable row cannot be confirmed" do
    (TEAMS - %w[team-f]).each { |team| @entry.selections.create!(slate_matchup: anchor(team)) }
    @entry.selections.create!(slate_matchup: later("team-f"))

    error = assert_raises(RuntimeError) { @entry.assert_enterable! }

    assert_match(/not a pickable/i, error.message)
  end

  # --- admin fill ---------------------------------------------------------

  test "fill seeds entries from pickable rows only" do
    pickable = @contest.pickable_matchups.map(&:id)
    @entry.destroy!
    @contest.update!(max_entries: 1)

    @contest.fill!(users: [ users(:jordan) ])

    filled = @contest.entries.confirmed.first
    assert filled, "fill created an entry"
    assert_empty filled.selections.map(&:slate_matchup_id) - pickable
  end
end
